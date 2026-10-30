#!/bin/sh
#
# build.sh — build ExampleBSD-style images from an UNMODIFIED FreeBSD tree.
#
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# OVERLAY RULE: src/ and ports/ are never patched. This script applies
# overlay/base and overlay/profiles/<profile> on top of stock FreeBSD and
# drives stock release(7)-style tooling:
#
#   make SRCCONF=overlay/base/src.conf buildworld buildkernel
#   make DESTDIR=<stage> installworld installkernel distribution
#   copy overlay rootfs over the stage; substitute @DISTRO_NAME@ @MOTD@ @SLUG@
#   pkg -r <stage> install -y   (the packages.list files)
#   makefs / mkimg             -> raw disk image (makefs -t zfs for ZFS roots)
#   sh src/release/<arch>/mkisoimages.sh -b  -> bootable ISO (-b = bootable)
#   sha256 -r                  -> out/SHA256
#
# product.conf is flat KEY=value output (parsed, never sourced) of wtfbsd/agents
# scripts/apply-answers.sh; the key list lives in wtfbsd/agents questions.yaml.
#
# Usage:
#   ./build.sh -c product.conf [-s /usr/src] [-o ./out] \
#              [-p desktop|appliance|both] [-u USER -k PUBKEYFILE] [-n]
#
#   -c  product.conf (required; DISTRO_OS must be freebsd)
#   -s  unmodified FreeBSD source tree (default /usr/src)
#   -o  output directory (default ./out)
#   -p  profile(s) to build; overrides PROFILE from product.conf
#   -n  dry run: validate config, print the plan, change nothing
#
# Environment knobs:
#   KERNCONF   kernel to build/install (default GENERIC)
#   ROOTSIZE   root filesystem size in the raw image (default 12g)
#   PKG_ABI    override package ABI for cross-arch pkg installs,
#              e.g. FreeBSD:15:aarch64 (same-arch builds ignore it)

set -eu

PROG=$(basename -- "$0")
log() { printf '%s\n' "$*"; }
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }

usage() {
	log "usage: $PROG -c product.conf [-s /usr/src] [-o ./out]"
	log '       [-p desktop|appliance|both] [-u USER -k PUBKEYFILE] [-n]'
	log ''
	log '  -c  product.conf from wtfbsd/agents scripts/apply-answers.sh'
	log '  -s  unmodified FreeBSD src tree (default /usr/src)'
	log '  -o  output directory (default ./out)'
	log '  -p  profile: desktop, appliance or both (default: product.conf PROFILE)'
	log '  -u + -k  bake firstboot-user.conf (USERNAME=USER and one SSH_KEY= line'
	log '           per line of PUBKEYFILE, mode 600) into the staged image; both'
	log '           options are required together. Intended for CI/test images.'
	log '  -n  dry run: print the plan, change nothing'
	exit "${1:-2}"
}

DRY=0
CONF=''
SRC=/usr/src
OUT=./out
CHOSEN=''
CIUSER=''
CIKEY=''

while getopts 'c:s:o:p:u:k:nh' _opt; do
	case $_opt in
	c) CONF=$OPTARG ;;
	s) SRC=$OPTARG ;;
	o) OUT=$OPTARG ;;
	p) CHOSEN=$OPTARG ;;
	u) CIUSER=$OPTARG ;;
	k) CIKEY=$OPTARG ;;
	n) DRY=1 ;;
	h) usage 0 ;;
	*) usage 2 >&2 ;;
	esac
done
shift $((OPTIND - 1))
[ $# -eq 0 ] || usage 2 >&2
[ -n "$CONF" ] || { log "$PROG: missing -c product.conf" >&2; usage 2 >&2; }
case $OUT in *[[:space:]]*) die "-o: output path may not contain whitespace: $OUT" ;; esac
[ -n "$OUT" ] || die '-o: output path may not be empty'
[ -f "$CONF" ] || die "no such product.conf: $CONF"

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# --------------------------------------------------------------------------
# load + validate product.conf (flat shell KEY=value from apply-answers.sh)
# --------------------------------------------------------------------------

# product.conf is NEVER sourced: it is parsed line by line, only the known
# questions.yaml keys are accepted, and values may not contain shell
# metacharacters. Exactly one outer pair of quotes is stripped: single or
# double, never a mix of the two and never a quote inside the pair.
# apply-answers.sh writes KEY='value', so the single quotes are the normal
# case.
KNOWN_KEYS='DISTRO_OS DISTRO_NAME DISTRO_SLUG DISTRO_ARCH FILESYSTEM_ROOT
ZFS_DATA_POOL ZFS_POOL_NAME PROFILE PACKAGE_SET INSTALLER MOTD BRAND_COLOR
BRAND_URL CI_ENABLED PUBLISH_METHOD PUBLISH_TARGET PUBLISHER_ORG'
for _k in $KNOWN_KEYS; do unset "$_k"; done
while IFS= read -r _line || [ -n "$_line" ]; do
	case $_line in '' | '#'*) continue ;; esac
	case $_line in
	[A-Z]*=*) ;;
	*) die "product.conf: not a KEY=value line: $_line" ;;
	esac
	_k=${_line%%=*}
	_v=${_line#*=}
	case " $(printf %s "$KNOWN_KEYS" | tr '\n' ' ') " in
	*" $_k "*) ;;
	*) die "product.conf: unknown key: $_k (known: $(printf %s "$KNOWN_KEYS" | tr '\n' ' '); see wtfbsd/agents questions.yaml)" ;;
	esac
	case $_v in
	\'*\')
		_v=${_v#\'}
		_v=${_v%\'}
		_quoted=yes
		;;
	\"*\")
		_v=${_v#\"}
		_v=${_v%\"}
		_quoted=yes
		;;
	\'*\" | \"*\')
		die "product.conf: $_k has a mix of single and double quotes"
		;;
	*)
		_quoted=no
		;;
	esac
	if [ "$_quoted" = yes ]; then
		case $_v in
		*\'* | *\"*) die "product.conf: $_k has a quote inside its quotes" ;;
		esac
	fi
	case $_v in
	*[\$\`\\\"]* | *[[:cntrl:]]*) die "product.conf: $_k contains a forbidden character (\$, backquote, backslash, double quote or control character)" ;;
	esac
	# plain assignments, no eval: the value is pure data
	case $_k in
	DISTRO_OS) DISTRO_OS=$_v ;;
	DISTRO_NAME) DISTRO_NAME=$_v ;;
	DISTRO_SLUG) DISTRO_SLUG=$_v ;;
	DISTRO_ARCH) DISTRO_ARCH=$_v ;;
	FILESYSTEM_ROOT) FILESYSTEM_ROOT=$_v ;;
	ZFS_DATA_POOL) ZFS_DATA_POOL=$_v ;;
	ZFS_POOL_NAME) ZFS_POOL_NAME=$_v ;;
	PROFILE) PROFILE=$_v ;;
	PACKAGE_SET) PACKAGE_SET=$_v ;;
	INSTALLER) INSTALLER=$_v ;;
	MOTD) MOTD=$_v ;;
	BRAND_COLOR) BRAND_COLOR=$_v ;;
	BRAND_URL) BRAND_URL=$_v ;;
	CI_ENABLED) CI_ENABLED=$_v ;;
	PUBLISH_METHOD) PUBLISH_METHOD=$_v ;;
	PUBLISH_TARGET) PUBLISH_TARGET=$_v ;;
	PUBLISHER_ORG) PUBLISHER_ORG=$_v ;;
	esac
done < "$CONF"

[ "${DISTRO_OS:-}" = freebsd ] \
	|| die "DISTRO_OS must be freebsd (got ${DISTRO_OS:-<empty>}); this template builds FreeBSD only"

# anchored checks without interval expressions (portable ERE)
chk() { # chk <anchored-ere> <value> <message>
	printf '%s\n' "$2" | grep -qE -- "$1" || die "$3 (got: $2)"
}

USER_RE='^[a-z_][a-z0-9_-]{0,31}$'

keyprefix() { # keyprefix <line> — an authorized_keys key type accepted by
	# firstboot_user and the installer (same list in both)
	case $1 in
	ssh-ed25519* | ssh-rsa* | ecdsa-sha2-nistp256* | ecdsa-sha2-nistp384* | ecdsa-sha2-nistp521* | sk-ssh-ed25519@openssh.com* | sk-ecdsa-sha2-nistp256@openssh.com*) return 0 ;;
	*) return 1 ;;
	esac
}

# slug: lowercase/digits/hyphens, starts with a letter, 2..32 chars
chk '^[a-z][a-z0-9-]*$' "${DISTRO_SLUG:-}" 'DISTRO_SLUG must match ^[a-z][a-z0-9-]*$'
[ "$(printf %s "$DISTRO_SLUG" | wc -c)" -ge 2 ] || die 'DISTRO_SLUG too short (min 2)'
[ "$(printf %s "$DISTRO_SLUG" | wc -c)" -le 32 ] || die 'DISTRO_SLUG too long (max 32)'

case ${DISTRO_NAME:-} in *[[:cntrl:]]*) die 'DISTRO_NAME contains control characters' ;; esac
[ -n "${DISTRO_NAME:-}" ] || die 'DISTRO_NAME is empty'
[ "$(printf %s "$DISTRO_NAME" | wc -c)" -le 64 ] || die 'DISTRO_NAME too long (max 64)'

FILESYSTEM_ROOT=${FILESYSTEM_ROOT:-zfs}
case $FILESYSTEM_ROOT in
ufs | zfs) ;;
*) die "FILESYSTEM_ROOT must be ufs or zfs for freebsd (got: $FILESYSTEM_ROOT)" ;;
esac

ZDP=${ZFS_DATA_POOL:-no}
case $ZDP in
yes | no) ;;
*) die "ZFS_DATA_POOL must be yes or no (got: $ZDP)" ;;
esac
[ "$ZDP" = no ] || {
	[ -n "${ZFS_POOL_NAME:-}" ] || die 'ZFS_DATA_POOL=yes requires ZFS_POOL_NAME'
	chk '^[a-z][a-z0-9-]*$' "$ZFS_POOL_NAME" 'ZFS_POOL_NAME must match ^[a-z][a-z0-9-]*$'
	[ "$(printf %s "$ZFS_POOL_NAME" | wc -c)" -le 29 ] || die 'ZFS_POOL_NAME too long (max 29)'
}

chk '^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$' \
	"${BRAND_COLOR:-3b6ea5}" 'BRAND_COLOR must be six hex digits'
BRAND_URL=${BRAND_URL:-https://example.org}
chk '^https://[A-Za-z0-9.-]+$' "$BRAND_URL" 'BRAND_URL must be https, hostname only'

PROF=${CHOSEN:-${PROFILE:-appliance}}
case $PROF in
desktop | appliance | both) ;;
*) die "-p must be desktop, appliance or both (got: $PROF)" ;;
esac

# informational defaults mirroring questions.yaml (used downstream)
PACKAGE_SET=${PACKAGE_SET:-minimal}
INSTALLER=${INSTALLER:-tui}
MOTD=${MOTD:-built from the wtfbsd templates}
case $MOTD in *[[:cntrl:]]*) die 'MOTD contains control characters' ;; esac
[ "$(printf %s "$MOTD" | wc -c)" -le 120 ] || die 'MOTD too long (max 120)'

# optional -u/-k: bake a firstboot-user.conf (mode 600) into the staged
# image with USERNAME=USER and one SSH_KEY= line per line of PUBKEYFILE.
# Validation is identical to rc.d/firstboot_user, in the dry run too.
if [ -n "${CIUSER:-}" ] || [ -n "${CIKEY:-}" ]; then
	[ -n "$CIUSER" ] && [ -n "$CIKEY" ] || die 'build.sh: -u USER and -k PUBKEYFILE must be given together'
	chk "$USER_RE" "$CIUSER" 'build.sh: -u: bad username'
	[ -f "$CIKEY" ] || die "build.sh: no such pubkey file: $CIKEY"
	_nkeys=0
	while IFS= read -r _kl || [ -n "$_kl" ]; do
		case $_kl in
		'' | '#'*) continue ;;
		esac
		keyprefix "$_kl" || die "build.sh: $CIKEY: not a supported ssh public key line: $_kl"
		_nkeys=$((_nkeys + 1))
	done < "$CIKEY"
	[ "$_nkeys" -gt 0 ] || die "build.sh: no ssh public key lines in $CIKEY"
	log "note: baking firstboot-user.conf (user $CIUSER, keys from $CIKEY)"
fi

# --------------------------------------------------------------------------
# static checks
# --------------------------------------------------------------------------

# The mt76 rule: the wireless driver is never enabled, loaded or configured
# by this template; an overlay file may not mention it at all.
[ -d "$ROOT/overlay" ] || die "mt76 guard: missing $ROOT/overlay"
_rc=0
grep -rna 'mt76' "$ROOT/overlay" || _rc=$?
case $_rc in
1) ;; # no match: good
0) die 'mt76 guard: an overlay file references the mt76 wireless driver; it must never be enabled or loaded by this template' ;;
*) die "mt76 guard: could not scan $ROOT/overlay (grep exit $_rc)" ;;
esac

SRCCONF="$ROOT/overlay/base/src.conf"
[ -f "$SRCCONF" ] || die "missing $SRCCONF"

: "${DISTRO_ARCH:=amd64}" # questions.yaml per_os default
MARC='' KARC='' BASEEFIBOOT=''
case $DISTRO_ARCH in
amd64) MARC=amd64; KARC=amd64; BASEEFIBOOT=BOOTX64.EFI ;;
aarch64) MARC=aarch64; KARC=arm64; BASEEFIBOOT=BOOTAA64.EFI ;;
*) die "DISTRO_ARCH must be amd64 or aarch64 (got: ${DISTRO_ARCH:-<empty>})" ;;
esac

if [ "$DRY" -ne 1 ]; then
	[ "$(uname -s)" = FreeBSD ] || die 'real builds need a FreeBSD host (use -n for a dry-run plan)'
	for t in make mkimg makefs pkg pw sha256; do
		command -v "$t" > /dev/null 2>&1 || die "required tool missing: $t (stock on FreeBSD; pkg is bootstrapped with: pkg bootstrap)"
	done
	[ -d "$SRC" ] || die "no such src tree: $SRC (clone an unmodified FreeBSD src there, or pass -s <path>)"
	[ -f "$SRC/Makefile" ] || die "$SRC does not look like a FreeBSD src tree"
fi

JOBS=$(sysctl -n hw.ncpu 2>/dev/null || echo 1)
KERNCONF=${KERNCONF:-GENERIC}
# makefs(8) reads the size of the filesystem with a lowercase suffix
# only: '12G' is an illegal number to it. The default is lowercase and a
# value that is given in uppercase is normalised before it reaches
# makefs(8) or mkimg(8).
ROOTSIZE=${ROOTSIZE:-12g}
chk '^[0-9]+[kKmMgGtT]?$' "$ROOTSIZE" 'ROOTSIZE must match ^[0-9]+[kKmMgGtT]?$ (a number with an optional k, m, g or t suffix)'
ROOTSIZE=$(printf '%s' "$ROOTSIZE" | tr 'A-Z' 'a-z')
ROOT_POOL="$(printf %s "$DISTRO_SLUG" | tr - _)_root" # makefs -t zfs pool name: a letter, then [A-Za-z0-9_] only (usr.sbin/makefs/zfs.c)

# TARGET/TARGET_ARCH only for cross builds
MAKETGT=''
if [ "$(uname -m)" != "$KARC" ]; then
	MAKETGT="TARGET=$KARC TARGET_ARCH=$MARC"
	log "note: cross build $(uname -m) -> $DISTRO_ARCH (advanced; package installs need ABI care)"
fi

# cd9660 volume label: uppercase alnum/underscore, <= 32 chars
VOL=$(printf %s "$DISTRO_NAME" | tr '[:lower:]' '[:upper:]' | tr -cs '[:upper:][:digit:]' '_' | cut -c1-32)

# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

step() { # step <cmd...> — execute, or print in a dry run
	if [ "$DRY" -eq 1 ]; then printf '    + %s\n' "$*"; else "$@"; fi
}

rmrf() { # rmrf <path> <guardroot> — rm -rf only for non-empty paths under root
	[ -n "${1:-}" ] || die 'rmrf: empty path'
	[ -n "${2:-}" ] || die 'rmrf: empty guard root'
	[ "$1" != "$2" ] || die "rmrf: refusing guard root itself: $1"
	case $1 in "$2"/*) ;; *) die "rmrf: refusing path outside $2: $1" ;; esac
	[ -d "$1" ] || return 0
	rm -rf -- "$1"
}

pkg_list() { # pkg_list file... — flatten lists to shell words
	sed -e 's/[[:space:]]*#.*$//' \
		-e 's/^[[:space:]]*//' \
		-e 's/[[:space:]]*$//' "$@" | grep -v '^$' | tr '\n' ' '
}

sed_esc() { # escape a value for use inside a sed replacement
	printf '%s' "$1" | sed -e 's/[\\&]/\\&/g'
}

SUBFILE=''
mk_subst() { # write a sed program under OUT; pick a delimiter absent from values
	SUBFILE="$OUT/.subst.sed"
	d=''
	for cand in '|' ',' ';' ':' '%'; do
		case "$DISTRO_NAME$MOTD$DISTRO_SLUG$BRAND_URL" in *"$cand"*) ;; *) d=$cand; break ;; esac
	done
	[ -n "$d" ] || die 'DISTRO_NAME/MOTD/DISTRO_SLUG/BRAND_URL contain every candidate sed delimiter (| , ; : %); remove one of those characters in product.conf'
	{
		printf 's%s@DISTRO_NAME@%s%s%sg\n' "$d" "$d" "$(sed_esc "$DISTRO_NAME")" "$d"
		printf 's%s@MOTD@%s%s%sg\n' "$d" "$d" "$(sed_esc "$MOTD")" "$d"
		printf 's%s@SLUG@%s%s%sg\n' "$d" "$d" "$(sed_esc "$DISTRO_SLUG")" "$d"
		printf 's%s@BRAND_URL@%s%s%sg\n' "$d" "$d" "$(sed_esc "$BRAND_URL")" "$d"
	} > "$SUBFILE"
}

subst_overlay() { # subst_overlay <stage> <overlay-rootfs-dir>
	_stg=$1 _ovr=$2
	find "$_ovr" -type f | while read -r f; do
		r=${f#"$_ovr"/}
		t="$_stg/$r"
		[ -f "$t" ] && [ ! -L "$t" ] || continue
		# the result is written back INTO the file, so that it keeps its
		# mode: a new file would get the mode of the umask, and a script
		# would lose its exec bit
		sed -f "$SUBFILE" "$t" > "$t.new" && cat "$t.new" > "$t" && rm -f "$t.new"
	done
}

own_overlay() { # own_overlay <stage> <overlay-rootfs-dir>
	# the overlay is copied with cp -Rp, so the owner and the modes of
	# the checkout end up in the image: every path that came from the
	# overlay is given to root:wheel and loses its group-write bit
	_stg=$1 _ovr=$2
	_lst=$(mktemp "${TMPDIR:-/tmp}/own_overlay.XXXXXX") || die 'mktemp failed'
	find "$_ovr" -print > "$_lst" || { rm -f "$_lst"; die "find $_ovr failed"; }
	while read -r _f; do
		_r=${_f#"$_ovr"/}
		[ "$_r" = "$_f" ] && continue
		_t="$_stg/$_r"
		# the staged name carries the slug, not the placeholder
		_t=$(printf '%s' "$_t" | sed -e "s%@SLUG@%$DISTRO_SLUG%g")
		[ -e "$_t" ] || [ -L "$_t" ] || continue
		chown -h 0:0 "$_t" || { rm -f "$_lst"; die "chown 0:0 $_t failed"; }
		# a symlink has no mode of its own: chmod would follow it out
		# of the stage
		if [ ! -L "$_t" ]; then
			chmod go-w "$_t" || { rm -f "$_lst"; die "chmod go-w $_t failed"; }
		fi
	done < "$_lst"
	rm -f "$_lst"
	return 0
}

abspath() { # abspath <path> — the absolute form of a path, without creating it
	case $1 in
	/*) printf '%s\n' "$1" ;;
	*)
		_d=$(dirname -- "$1")
		_b=$(basename -- "$1")
		if [ -d "$_d" ]; then
			printf '%s\n' "$(CDPATH='' cd -- "$_d" && pwd)/$_b"
		else
			case $1 in
			./*) printf '%s\n' "$(pwd)/${1#./}" ;;
			*) printf '%s\n' "$(pwd)/$1" ;;
			esac
		fi
		;;
	esac
}

# The output directory is made absolute before the build starts: the build
# runs make(1) inside the source tree, where a relative DESTDIR lands in
# the source tree instead of in the output directory. A dry run changes
# nothing, so there the path is resolved without creating anything.
if [ "$DRY" -eq 1 ]; then
	OUT=$(abspath "$OUT")
else
	mkdir -p -- "$OUT" || die "cannot create the output directory: $OUT"
	OUT=$(CDPATH='' cd -- "$OUT" && pwd) || die "cannot enter the output directory: $OUT"
fi

# --------------------------------------------------------------------------
# plan header
# --------------------------------------------------------------------------

log ''
log 'plan:'
log "  distro   $DISTRO_NAME ($DISTRO_SLUG), freebsd/$DISTRO_ARCH"
log "  rootfs   $FILESYSTEM_ROOT (pool: $ROOT_POOL, data pool: $ZDP${ZFS_POOL_NAME:+ ($ZFS_POOL_NAME)})"
log "  profile  $PROF (package set: $PACKAGE_SET, installer: $INSTALLER)"
log "  src      $SRC (unmodified; SRCCONF=$SRCCONF)"
log "  out      $OUT  (jobs: $JOBS, kernel: $KERNCONF, rootsize: $ROOTSIZE)"

case $PROF in both) profiles='appliance desktop' ;; *) profiles=$PROF ;; esac

# --------------------------------------------------------------------------
# per-profile pipeline
# --------------------------------------------------------------------------

RELS='' # relative artifact paths; safe to word-split: DISTRO_SLUG is [a-z0-9-]

# world and kernel are profile-independent: build them once
log ''
log '==> buildworld/buildkernel (SRCCONF, -j'"$JOBS"')'
step make -C "$SRC" -j "$JOBS" "SRCCONF=$SRCCONF" $MAKETGT "KERNCONF=$KERNCONF" buildworld
step make -C "$SRC" -j "$JOBS" "SRCCONF=$SRCCONF" $MAKETGT "KERNCONF=$KERNCONF" buildkernel

for p in $profiles; do
	log ''
	log "==> profile: $p"

	PSUB="$OUT/$p"
	STAGE="$PSUB/stage"
	PARTS="$PSUB/parts"
	img="$PSUB/$DISTRO_SLUG-$p-$DISTRO_ARCH.img"
	iso="$PSUB/$DISTRO_SLUG-$p-$DISTRO_ARCH.iso"

	[ "$DRY" -eq 1 ] || {
		rmrf "$STAGE" "$OUT"
		rmrf "$PARTS" "$OUT"
		mkdir -p "$STAGE" "$PARTS"
	}

	# 2. install world/kernel/distribution into the stage
	log "  [2] installworld/installkernel/distribution -> stage"
	step make -C "$SRC" -j "$JOBS" "SRCCONF=$SRCCONF" $MAKETGT "KERNCONF=$KERNCONF" "DESTDIR=$STAGE" installworld
	step make -C "$SRC" -j "$JOBS" "SRCCONF=$SRCCONF" $MAKETGT "KERNCONF=$KERNCONF" "DESTDIR=$STAGE" installkernel
	step make -C "$SRC" "SRCCONF=$SRCCONF" $MAKETGT "DESTDIR=$STAGE" distribution

	# 3. copy overlay rootfs: base first, then the profile on top
	log '  [3] overlay copy + placeholder substitution'
	if [ "$DRY" -eq 1 ]; then
		printf '    + cp -Rp %s/rootfs/. %s/\n' "$ROOT/overlay/base" "$STAGE"
		printf '    + cp -Rp %s/rootfs/. %s/\n' "$ROOT/overlay/profiles/$p" "$STAGE"
		printf '    + sed -f %s (every staged overlay file: @DISTRO_NAME@ @MOTD@ @SLUG@ @BRAND_URL@)\n' "$OUT/.subst.sed"
		printf '    + rename staged files/dirs whose NAME contains @SLUG@ -> %s\n' "$DISTRO_SLUG"
		printf '    + chown 0:0 + chmod go-w on every path of the overlay (base, profile)\n'
		printf '    + cp %s/etc/motd.template -> %s/etc/motd\n' "$STAGE" "$STAGE"
	else
		mk_subst
		cp -Rp "$ROOT/overlay/base/rootfs/." "$STAGE/"
		cp -Rp "$ROOT/overlay/profiles/$p/rootfs/." "$STAGE/"
		subst_overlay "$STAGE" "$ROOT/overlay/base/rootfs"
		subst_overlay "$STAGE" "$ROOT/overlay/profiles/$p/rootfs"
		# staged files whose NAME contains @SLUG@ (e.g.
		# usr/local/sbin/@SLUG@-install) belong to the product: rename
		# them to the slug (content placeholders were substituted above,
		# which is why the rename comes after subst_overlay)
		_slugs=$(find "$STAGE" -depth -name '*@SLUG@*')
		for _sf in $_slugs; do
			_sf_new=$(printf %s "$_sf" | sed -e "s%@SLUG@%$DISTRO_SLUG%g")
			if [ "$_sf" != "$_sf_new" ]; then
				mv "$_sf" "$_sf_new"
			fi
		done
		# the overlay was copied with cp -Rp: the owner and the modes of
		# the checkout are in the image, so every path that came from the
		# overlay is given to root:wheel and loses its group-write bit
		own_overlay "$STAGE" "$ROOT/overlay/base/rootfs"
		own_overlay "$STAGE" "$ROOT/overlay/profiles/$p/rootfs"
		# motd.template stays installed (rc.d/motd reuses it each boot);
		# also make it the live /etc/motd for the first login
		cp "$STAGE/etc/motd.template" "$STAGE/etc/motd"
	fi

	# 3a. root filesystem wiring: the stock distribution writes no fstab
	# and no ZFS loader knobs, so an image would not find or mount its root
	log "  [3a] root fs wiring for $FILESYSTEM_ROOT"
	# the fstab of a ZFS root: the header line the stock installer writes
	# and nothing else (the root dataset is mounted by the loader)
	FSTAB_ZFS=$(printf '# Device\tMountpoint\tFStype\tOptions\tDump\tPass#')
	if [ "$DRY" -eq 1 ]; then
		case $FILESYSTEM_ROOT in
		zfs)
			printf '    + boot/loader.conf.d/zfs.conf: zfs_load="YES"; etc/rc.conf.d/zfs: zfs_enable="YES"\n'
			printf '    + etc/fstab: %s\n' "$FSTAB_ZFS"
			;;
		*) printf '    + etc/fstab: /dev/ufs/%s-root / ufs rw 1 1\n' "$DISTRO_SLUG" ;;
		esac
	else
		case $FILESYSTEM_ROOT in
		zfs)
			mkdir -p "$STAGE/boot/loader.conf.d" "$STAGE/etc/rc.conf.d"
			printf 'zfs_load="YES"\n' > "$STAGE/boot/loader.conf.d/zfs.conf"
			printf 'zfs_enable="YES"\n' > "$STAGE/etc/rc.conf.d/zfs"
			printf '%s\n' "$FSTAB_ZFS" > "$STAGE/etc/fstab"
			;;
		*)
			printf '/dev/ufs/%s-root\t/\tufs\trw\t1\t1\n' "$DISTRO_SLUG" > "$STAGE/etc/fstab"
			;;
		esac
	fi

	# 3b. stock distribution leaves root with an EMPTY password: lock it.
	# Login is by an operator-provisioned account / SSH key (first boot).
	log '  [3b] lock root in the stage (pw -R ... lock root)'
	step pw -R "$STAGE" lock root

	# 3c. first-boot sentinel: rc(8) only runs KEYWORD firstboot scripts
	# while /firstboot exists and removes it after processing.
	log '  [3c] touch $STAGE/firstboot (first-boot sentinel)'
	step touch "$STAGE/firstboot"

	# 3d. optional -u/-k: bake a CI/test first-boot user into the image
	if [ -n "${CIUSER:-}" ]; then
		log "  [3d] write $STAGE/boot/firstboot-user.conf (mode 600)"
		if [ "$DRY" -eq 1 ]; then
			printf '    + write %s/boot/firstboot-user.conf (mode 600; USERNAME=%s, SSH_KEY lines from %s)\n' \
				"$STAGE" "$CIUSER" "$CIKEY"
		else
			_ci="$STAGE/boot/firstboot-user.conf"
			_oldumask=$(umask)
			umask 077 # no world-readable window on a (potential) hash
			printf 'USERNAME=%s\n' "$CIUSER" > "$_ci"
			while IFS= read -r _kl || [ -n "$_kl" ]; do
				case $_kl in
				'' | '#'*) continue ;;
				esac
				printf 'SSH_KEY=%s\n' "$_kl" >> "$_ci"
			done < "$CIKEY"
			umask "$_oldumask"
			chmod 600 "$_ci"
		fi
	fi

	# 4. packages: base list + profile list, installed into the stage
	log '  [4] pkg install (base + profile lists)'
	pkgs=$(pkg_list "$ROOT/overlay/base/packages.list" "$ROOT/overlay/profiles/$p/packages.list")
	if [ -n "$pkgs" ]; then
		# cross-arch builds: set PKG_ABI (e.g. FreeBSD:15:aarch64); the
		# recommended path is to build on a VM of the matching arch.
		if [ -n "${PKG_ABI:-}" ]; then
			step env "ABI=$PKG_ABI" pkg -r "$STAGE" install -y $pkgs
		else
			step pkg -r "$STAGE" install -y $pkgs
		fi
	fi
	rimg=${img#"$OUT"/}
	riso=${iso#"$OUT"/}
	RELS="$RELS $rimg $riso"

	# 5. appliance: serial getty always enabled — on the STAGED copy only
	if [ "$p" = appliance ]; then
		log '  [5] staged /etc/ttys: ttyu0 onifconsole -> on (upstream tree untouched)'
		ttys="$STAGE/etc/ttys"
		if [ "$DRY" -eq 1 ]; then
			printf '    + sed -E "s/^(ttyu0.*[[:space:]])onifconsole([[:space:]]+secure[[:space:]]*)$/\\1on\\2/" %s\n' "$ttys"
		else
			[ -f "$ttys" ] || die "missing staged $ttys"
			sed -E 's/^(ttyu0.*[[:space:]])onifconsole([[:space:]]+secure[[:space:]]*)$/\1on\2/' \
				"$ttys" > "$ttys.new"
			mv "$ttys.new" "$ttys"
		fi
		# FreeBSD's stock sshd_config has no Include line; add one to the
		# STAGED copy so overlay sshd_config.d drop-ins take effect
		sshc="$STAGE/etc/ssh/sshd_config"
		if [ "$DRY" -ne 1 ] && [ ! -f "$sshc" ]; then
			die "missing staged $sshc (is OpenSSH disabled in src.conf?)"
		fi
		if [ "$DRY" -eq 1 ]; then
			printf '    + append "Include /etc/ssh/sshd_config.d/*.conf" to %s\n' "$sshc"
		elif ! grep -q '^Include /etc/ssh/sshd_config.d/' "$sshc"; then
			printf '\nInclude /etc/ssh/sshd_config.d/*.conf\n' >> "$sshc"
		fi
	else
		log '  [5] tty handling: vt(4) default, nothing to change'
	fi

	# 6. raw image: pmbr + boot + EFI + root partition, via makefs/mkimg
	log '  [6] raw image (makefs/mkimg)'
	case $FILESYSTEM_ROOT in
	zfs)
		img_type='freebsd-zfs'
		img_boot="$STAGE/boot/gptzfsboot"
		case $DRY in
		1) printf '    + makefs -t zfs -s %s -o poolname=%s -o bootfs=%s %s %s\n' \
			"$ROOTSIZE" "$ROOT_POOL" "$ROOT_POOL" "$PARTS/root.img" "$STAGE" ;;
		*)
			# ZFS root: one pool via makefs(8) zfs backend; the loader
			# imports it automatically off bootfs at boot time.
			makefs -t zfs -s "$ROOTSIZE" \
				-o "poolname=$ROOT_POOL" \
				-o "bootfs=$ROOT_POOL" \
				"$PARTS/root.img" "$STAGE"
			;;
		esac
		;;
	*)
		img_type='freebsd-ufs'
		img_boot="$STAGE/boot/gptboot"
		step makefs -t ffs -B little -s "$ROOTSIZE" \
			-o version=2 -o "label=${DISTRO_SLUG}-root" \
			"$PARTS/root.img" "$STAGE"
		;;
	esac
	if [ "$DRY" -eq 1 ]; then
		printf '    + cp %s/boot/loader.efi EFI/BOOT/%s; makefs -t msdos -s 100m\n' "$STAGE" "$BASEEFIBOOT"
		printf '    + mkimg -s gpt (pmbr, freebsd-boot, efi, %s) -o %s\n' "$img_type" "$img"
	else
		if [ "$KARC" = amd64 ]; then
			[ -f "$img_boot" ] || die "missing BIOS boot block $img_boot"
			BIOSPARTS="-b $STAGE/boot/pmbr -p freebsd-boot:=$img_boot"
		else
			BIOSPARTS='' # arm64 boots UEFI only: no pmbr/gptboot
		fi
		mkdir -p "$PARTS/efi/EFI/BOOT"
		cp "$STAGE/boot/loader.efi" "$PARTS/efi/EFI/BOOT/$BASEEFIBOOT"
		makefs -t msdos -s 100m -o volume_label=EFISYS "$PARTS/efi.img" "$PARTS/efi"
		# BIOSPARTS is unquoted on purpose: it is empty on arm64 and
		# its paths come from OUT (whitespace refused above) and the slug
		mkimg -s gpt $BIOSPARTS \
			-p "efi:=$PARTS/efi.img" \
			-p "$img_type:=$PARTS/root.img" \
			-o "$img"
	fi
	log "    -> $img"

	# 6b. ISO-only: carry the raw image for the on-disk installer + a motd
	# hint. The raw image [6] was built from the stage BEFORE system.img
	# was copied in, so the finished .img stays as small as possible.
	imgdir="$STAGE/usr/local/share/$DISTRO_SLUG/install"
	log '  [6b] stage system.img + motd hint (ISO only)'
	if [ "$DRY" -eq 1 ]; then
		printf '    + mkdir -p %s; xz -c %s > %s/system.img.xz\n' "$imgdir" "$img" "$imgdir"
		printf '    + append "Install to disk: run %s-install as root" to %s/etc/motd\n' "$DISTRO_SLUG" "$STAGE"
		printf '    + write %s/etc/rc.local (ISO only: run the installer on the console)\n' "$STAGE"
		printf '    + (after the ISO) rm -rf %s; rm etc/rc.local; restore /etc/motd\n' "$imgdir"
	else
		mkdir -p "$imgdir"
		# xz: ISO9660 cannot hold a file over 4 GiB and the raw image is
		# mostly zeroes; the installer streams it back with xz -dc
		xz -T0 -c "$img" > "$imgdir/system.img.xz"
		cp "$STAGE/etc/motd" "$PSUB/.motd.iso"
		printf 'Install to disk: run %s-install as root.\n' "$DISTRO_SLUG" >> "$STAGE/etc/motd"
		# root is locked, so the live ISO starts the installer itself on
		# the console (like stock FreeBSD install media); ISO only
		cat > "$STAGE/etc/rc.local" <<RCLOCAL
#!/bin/sh
# ISO only (written by build.sh [6b]): run the installer on the console.
exec < /dev/console > /dev/console 2>&1
while :; do
	/usr/local/sbin/$DISTRO_SLUG-install
	printf '\n[i]nstall again, [s]hell, [r]eboot, [p]oweroff? '
	read -r _a || _a=r
	case \$_a in
	s) /bin/sh ;;
	r) shutdown -r now; exit 0 ;;
	p) shutdown -p now; exit 0 ;;
	esac
done
RCLOCAL
	fi

	# 7. ISO with the stock release script
	log "  [7] ISO via stock src/release/$KARC/mkisoimages.sh" # KARC = machine name = release/ subdir
	step sh "$SRC/release/$KARC/mkisoimages.sh" -b "$VOL" "$iso" "$STAGE"
	log "    -> $iso"
	if [ "$DRY" -ne 1 ]; then
		# the install image lives on the ISO only; the raw image was
		# already written without it (and the motd hint is ISO-only)
		rmrf "$imgdir" "$OUT"
		rm -f "$STAGE/etc/rc.local"
		mv "$PSUB/.motd.iso" "$STAGE/etc/motd"
	fi

	log "profile done: $p (kernel $KERNCONF, root $FILESYSTEM_ROOT)"
done

# --------------------------------------------------------------------------
# checksums
# --------------------------------------------------------------------------

log ''
log '== checksums =='
if [ "$DRY" -eq 1 ]; then
	printf '    + (cd %s && sha256 -r %s) > %s/SHA256\n' "$OUT" "${RELS# }" "$OUT"
else
	(cd "$OUT" && sha256 -r $RELS) > "$OUT/SHA256"
	log "wrote: $OUT/SHA256"
fi
log 'artifacts:'
for rel in $RELS; do
	log "  $OUT/$rel"
done

if [ "$DRY" -eq 1 ]; then
	log ''
	log 'dry run: plan printed above; nothing was built'
else
	log ''
	log "done: $profiles under $OUT"
fi
