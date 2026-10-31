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
#   pkg -c <stage> triggers     (the triggers pkg -r deferred), then the
#                               package cache and the debug files go
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
#   ALLOW_KMOD_MISMATCH  yes builds although a kmod package was built for
#              another __FreeBSD_version than the kernel (default no: fail)
#   KMOD_REBUILD  yes (default) rebuilds a kmod package built for another
#              __FreeBSD_version from the ports tree against the src tree
#   PORTS      the ports tree of KMOD_REBUILD (default /usr/ports)
#   KEEP_DEBUG yes keeps /usr/lib/debug (kernel.debug and the debug files
#              of world) in the image (default no: they are removed)

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
	log '  JOBS=<n>  make(1) job count, defaulting to hw.ncpu (a positive integer)'
	log '  ALLOW_KMOD_MISMATCH=yes  warn instead of failing on a kmod package built for another kernel'
	log '  KMOD_REBUILD=no  keep the repository kmods (default yes: rebuild a mismatched one from PORTS)'
	log '  PORTS=<dir>  the ports tree KMOD_REBUILD uses (default /usr/ports)'
	log '  KEEP_DEBUG=yes  keep /usr/lib/debug and kernel.debug in the image (default no)'
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

# JOBS is the make(1) job count. It defaults to hw.ncpu; the caller may
# override it, but the result has to be a positive integer.
JOBS=${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 1)}
chk '^[1-9][0-9]*$' "$JOBS" 'JOBS must be a positive integer'
KERNCONF=${KERNCONF:-GENERIC}
# KEEP_DEBUG=yes keeps the standalone debug files of world and kernel
# (/usr/lib/debug, kernel.debug) in the image; the default removes them
KEEP_DEBUG=${KEEP_DEBUG:-no}
case $KEEP_DEBUG in
yes | no) ;;
*) die "KEEP_DEBUG must be yes or no (got: $KEEP_DEBUG)" ;;
esac
# ALLOW_KMOD_MISMATCH=yes turns a kmod package that was built for
# another __FreeBSD_version than the kernel of the image into a warning
ALLOW_KMOD_MISMATCH=${ALLOW_KMOD_MISMATCH:-no}
case $ALLOW_KMOD_MISMATCH in
yes | no) ;;
*) die "ALLOW_KMOD_MISMATCH must be yes or no (got: $ALLOW_KMOD_MISMATCH)" ;;
esac
# KMOD_REBUILD=yes rebuilds a kmod package built for another
# __FreeBSD_version from the ports tree PORTS against the src tree
KMOD_REBUILD=${KMOD_REBUILD:-yes}
case $KMOD_REBUILD in
yes | no) ;;
*) die "KMOD_REBUILD must be yes or no (got: $KMOD_REBUILD)" ;;
esac
PORTS=${PORTS:-/usr/ports}
case $PORTS in *[[:space:]]*) die "PORTS may not contain whitespace: $PORTS" ;; esac
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

rename_slug() { # rename_slug <stage> — rename every staged path whose NAME
	# carries @SLUG@ (e.g. usr/local/sbin/@SLUG@-install,
	# lightdm.conf.d/50-@SLUG@.conf) to the slug; -depth renames the
	# children of a directory before the directory itself
	find "$1" -depth -name '*@SLUG@*' | while IFS= read -r _sf; do
		_sf_new=$(printf %s "$_sf" | sed -e "s%@SLUG@%$DISTRO_SLUG%g")
		if [ "$_sf" != "$_sf_new" ]; then
			mv "$_sf" "$_sf_new" || die "rename $_sf failed"
		fi
	done
}

strip_xspice_conf() { # strip_xspice_conf <stage>
	# xf86-video-qxl installs xorg.conf.d/spiceqxl.xorg.conf from its
	# sample: that file makes the Xspice driver the only screen, and
	# Xorg dies with signal 11 on every machine. The driver itself stays
	# installed; only the configuration file is removed (the .example
	# copy next to it does not end in .conf, so Xorg does not read it).
	_x="$1/usr/local/etc/X11/xorg.conf.d/spiceqxl.xorg.conf"
	if [ -e "$_x" ] || [ -L "$_x" ]; then
		rm -f -- "$_x" || die "cannot remove $_x"
	fi
	return 0
}

has_entries() { # has_entries <dir> — does the directory hold a visible entry?
	[ -d "$1" ] && [ -n "$(ls -- "$1")" ]
}

stage_cache() { # stage_cache <stage> <output> <tool> <args...>
	# runs <tool> inside the stage with chroot(8) when the tool is in
	# the stage and <output> is not; fails the build when the tool fails
	# or leaves no <output>
	_st=$1 _o=$2 _t=$3
	shift 3
	[ -x "$_st$_t" ] || return 0
	[ -e "$_st$_o" ] && return 0
	chroot "$_st" "$_t" "$@" || die "chroot $_st $_t $* failed"
	[ -e "$_st$_o" ] || die "chroot $_st $_t $* left no $_o"
}

pkg_triggers() { # pkg_triggers <stage>
	# pkg -r installs into the stage but defers every trigger that is
	# not sandboxed: it writes it to <stage>/var/db/pkg/triggers instead
	# of running it, because its commands (gdk-pixbuf-query-loaders,
	# glib-compile-schemas, update-mime-database, fc-cache, ...) have to
	# run against the files of the stage. pkg -c chroots into the stage
	# first, so "pkg triggers" runs each deferred trigger with the
	# binaries and the files of the stage, and deletes the ones that
	# succeeded; one that is left over has failed.
	# a cross-arch stage (PKG_ABI) holds binaries the build host cannot
	# run: the triggers, the caches and the chroot steps are skipped
	if [ -n "${PKG_ABI:-}" ]; then
		printf '%s\n' "WARNING: PKG_ABI=$PKG_ABI: the stage binaries cannot run here; the package triggers, the caches and the dbus helper group are left undone" >&2
		return 0
	fi
	_td="$1/var/db/pkg/triggers"
	if has_entries "$_td"; then
		pkg -c "$1" triggers || die "pkg -c $1 triggers failed"
		if has_entries "$_td"; then
			die "deferred package triggers failed in the stage: $(ls -- "$_td" | tr '\n' ' ')"
		fi
	fi
	# the caches the greeter needs, built in the stage when a trigger did
	# not build them (a pkg that ran the trigger outside the stage)
	stage_cache "$1" /usr/local/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache \
		/usr/local/bin/gdk-pixbuf-query-loaders --update-cache
	stage_cache "$1" /usr/local/share/glib-2.0/schemas/gschemas.compiled \
		/usr/local/bin/glib-compile-schemas /usr/local/share/glib-2.0/schemas
	stage_cache "$1" /usr/local/share/mime/mime.cache \
		/usr/local/bin/update-mime-database /usr/local/share/mime
	# pkg -r looks the group of a packaged file up on the build host,
	# which has no messagebus group: the dbus launch helper ends up
	# root:wheel and dbus refuses to start Accounts and ConsoleKit. Its
	# plist sets root:messagebus 4750; chroot resolves the group in the
	# stage. chown comes first, because chown clears the setuid bit.
	_h=/usr/local/libexec/dbus-daemon-launch-helper
	if [ -f "$1$_h" ]; then
		chroot "$1" /usr/sbin/chown root:messagebus "$_h" || die "chown root:messagebus $_h in the stage failed"
		chroot "$1" /bin/chmod 4750 "$_h" || die "chmod 4750 $_h in the stage failed"
	fi
	return 0
}

in_stage() { # in_stage <stage> <path> — refuse a path that leaves the stage
	# a symlink on the way (a staged var -> /var) would make rm -rf
	# delete outside the stage: the real path of the parent of <path>
	# and of <path> itself (a directory, a file, or a symlink to either)
	# must be the stage or lie under it; a symlink that cannot be
	# resolved (it dangles) is refused too
	_sr=$(realpath "$1") || die "realpath $1 failed"
	for _p in "$(dirname -- "$2")" "$2"; do
		[ -e "$_p" ] || [ -L "$_p" ] || continue
		_pr=$(realpath "$_p") || die "refusing $2: $_p does not resolve (a dangling symlink in the stage)"
		case $_pr in
		"$_sr" | "$_sr"/*) ;;
		*) die "refusing $2: it resolves to $_pr, outside the stage $_sr (a symlink in the stage)" ;;
		esac
	done
}

prune_stage() { # prune_stage <stage> — drop the package cache and the debug files
	in_stage "$1" "$1/var/cache/pkg"
	in_stage "$1" "$1/usr/lib/debug"
	in_stage "$1" "$1/boot"
	# the packages pkg -r downloaded are cached in the stage: they are
	# removed, the empty cache directory stays
	rmrf "$1/var/cache/pkg" "$OUT"
	mkdir -p "$1/var/cache/pkg" || die "cannot create $1/var/cache/pkg"
	# the standalone debug files of world and kernel (/usr/lib/debug,
	# kernel.debug and *.ko.debug among them) are removed unless
	# KEEP_DEBUG=yes
	if [ "$KEEP_DEBUG" != yes ]; then
		rmrf "$1/usr/lib/debug" "$OUT"
		if [ -d "$1/boot" ]; then
			find "$1/boot" -type f -name '*.debug' -exec rm -f -- {} + \
				|| die "cannot remove the debug files under $1/boot"
		fi
	fi
	return 0
}

src_version() { # src_version <src> — the __FreeBSD_version of a src tree
	sed -n 's/^#define[[:space:]][[:space:]]*__FreeBSD_version[[:space:]][[:space:]]*\([0-9][0-9]*\).*/\1/p' \
		"$1/sys/sys/param.h" 2> /dev/null | head -1
}

pkg_note() { # pkg_note <stage> <package> <annotation> — its value, or nothing
	pkg -r "$1" query '%At %Av' "$2" | awk -v k="$3" '$1 == k { print $2; exit }'
}

KMOD_MM=''
kmod_mismatches() { # kmod_mismatches <stage> <version> — sets KMOD_MM
	# KMOD_MM gets one "name built-for" line per installed package that
	# owns a *.ko file and whose FreeBSD_version annotation is not
	# <version> ("none" when it has none). A package is a kmod by what it
	# ships, not by its name: the meta packages (drm-kmod,
	# gpu-firmware-kmod, nvidia-drm-kmod) own no .ko and carry no
	# FreeBSD_version annotation, so they are not looked at.
	_q=$(pkg -r "$1" query -a '%n %Fp') || die "pkg -r $1 query -a '%n %Fp' failed"
	KMOD_MM=''
	for _n in $(printf '%s\n' "$_q" | awk '$2 ~ /\.ko$/ { print $1 }' | sort -u); do
		_pv=$(pkg_note "$1" "$_n" FreeBSD_version)
		[ "$_pv" = "$2" ] || KMOD_MM="$KMOD_MM$_n ${_pv:-none}
"
	done
}

need_ports() { # need_ports — the ports tree the kmods are rebuilt from
	[ -f "$PORTS/Mk/bsd.port.mk" ] || die "KMOD_REBUILD=yes needs a ports tree at $PORTS (PORTS=<dir>); get one with: git clone --depth 1 https://git.FreeBSD.org/ports.git $PORTS
or build with KMOD_REBUILD=no ALLOW_KMOD_MISMATCH=yes to keep the repository's kmods"
}

rebuild_kmods() { # rebuild_kmods <stage> <src>
	# every package that owns a .ko and was built for another
	# __FreeBSD_version than <src> is rebuilt from the ports tree against
	# <src> and installed into the stage over the repository's copy, then
	# locked so that a pkg upgrade does not bring the repository's copy
	# back. pkg create writes the FreeBSD_version annotation from the ABI
	# and OSVERSION of its environment, so both are set for make.
	[ "$KMOD_REBUILD" = yes ] || return 0
	_rst=$1 _rsrc=$2
	_kv=$(src_version "$_rsrc")
	[ -n "$_kv" ] || die "cannot read __FreeBSD_version from $_rsrc/sys/sys/param.h: check that SRC is a complete FreeBSD src tree (sys/sys/param.h)"
	kmod_mismatches "$_rst" "$_kv"
	[ -n "$KMOD_MM" ] || return 0
	if [ -n "${PKG_ABI:-}" ]; then
		die "kmod packages need a rebuild for $_kv, which a cross build cannot do:
$KMOD_MM
build on a host of the target arch, or set KMOD_REBUILD=no ALLOW_KMOD_MISMATCH=yes"
	fi
	need_ports
	# __FreeBSD_version is major * 100000 + minor * 1000 + patch level
	# (sys/sys/param.h), so the major version is the quotient by 100000
	_abi="FreeBSD:$((_kv / 100000)):$MARC"
	# the ports framework writes PKGFILE only into an existing PACKAGES
	# directory (a fresh clone of the ports tree has none): the rebuilt
	# packages go to a directory of this build, emptied first, so no
	# package of an earlier build or of the ports tree is picked up
	_kp="$OUT/kmod-packages"
	rmrf "$_kp" "$OUT"
	mkdir -p "$_kp" || die "cannot create $_kp"
	for _n in $(printf '%s' "$KMOD_MM" | awk '{ print $1 }'); do
		_pv=$(printf '%s' "$KMOD_MM" | awk -v n="$_n" '$1 == n { print $2; exit }')
		_o=$(pkg -r "$_rst" query %o "$_n") || die "pkg -r $_rst query %o $_n failed"
		# the origin and the flavor reach make(1) as values: only the
		# characters of a port directory and of a flavor name pass
		printf '%s\n' "$_o" | grep -Eqx '[A-Za-z0-9_.+-]+/[A-Za-z0-9_.+-]+' \
			|| die "$_n: refusing the origin '$_o' (not category/port)"
		[ -f "$PORTS/$_o/Makefile" ] || die "$_n: no port $PORTS/$_o to rebuild it from"
		_fl=$(pkg_note "$_rst" "$_n" flavor)
		if [ -n "$_fl" ]; then
			printf '%s\n' "$_fl" | grep -Eqx '[A-Za-z0-9_]+' \
				|| die "$_n: refusing the flavor '$_fl' (not [A-Za-z0-9_]+)"
		fi
		log "    rebuild $_n ($_o${_fl:+@$_fl}): built for $_pv, kernel is $_kv"
		set -- "SRC_BASE=$_rsrc" "OSVERSION=$_kv" BATCH=yes DISABLE_VULNERABILITIES=yes "PACKAGES=$_kp"
		[ -z "$_fl" ] || set -- "$@" "FLAVOR=$_fl"
		env "ABI=$_abi" "OSVERSION=$_kv" make -C "$PORTS/$_o" "$@" clean package \
			|| die "make package of $_o failed"
		_pf=$(env "ABI=$_abi" "OSVERSION=$_kv" make -C "$PORTS/$_o" "$@" -V PKGFILE) \
			|| die "make -V PKGFILE of $_o failed"
		[ -f "$_pf" ] || die "make package of $_o left no $_pf"
		pkg -r "$_rst" add -f "$_pf" || die "pkg -r $_rst add -f $_pf failed"
		pkg -r "$_rst" lock -y "$_n" || die "pkg -r $_rst lock -y $_n failed"
	done
}

check_kmods() { # check_kmods <stage> <src>
	# a kernel module only works on the kernel it was built for: every
	# package that owns a .ko must carry the __FreeBSD_version of <src>
	# (from which the kernel of the image is built) in its
	# FreeBSD_version annotation. A mismatch fails the build unless
	# ALLOW_KMOD_MISMATCH=yes, which turns it into a warning.
	_kv=$(src_version "$2")
	[ -n "$_kv" ] || die "cannot read __FreeBSD_version from $2/sys/sys/param.h: check that SRC is a complete FreeBSD src tree (sys/sys/param.h)"
	kmod_mismatches "$1" "$_kv"
	_bad=$(printf '%s' "$KMOD_MM" | awk -v k="$_kv" '{ printf "\n  %s: built for %s, kernel is %s", $1, $2, k }')
	[ -n "$_bad" ] || return 0
	if [ "$ALLOW_KMOD_MISMATCH" = yes ]; then
		printf '%s\n' "WARNING: kmod packages do not match the kernel (__FreeBSD_version $_kv of $2); ALLOW_KMOD_MISMATCH=yes, building anyway:$_bad" >&2
		return 0
	fi
	die "kmod packages do not match the kernel (__FreeBSD_version $_kv of $2):$_bad
KMOD_REBUILD=yes rebuilds them from the ports tree; ALLOW_KMOD_MISMATCH=yes builds anyway"
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

# a desktop image installs kmods: with KMOD_REBUILD=yes the ports tree has
# to be there before hours of buildworld, not after them
case $PROF in
desktop | both)
	if [ "$KMOD_REBUILD" = yes ]; then
		# a cross build (PKG_ABI) cannot rebuild kmods at all: it
		# refuses later, and only when a kmod does not match
		if [ -n "${PKG_ABI:-}" ]; then
			:
		elif [ "$DRY" -eq 1 ]; then
			[ -f "$PORTS/Mk/bsd.port.mk" ] || log "note: no ports tree at $PORTS; the real build refuses to start (KMOD_REBUILD=yes)"
		else
			need_ports
		fi
	fi
	;;
esac

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
		rename_slug "$STAGE" || die 'the @SLUG@ rename of the stage failed'
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

	# 4a. the kmods are rebuilt for the kernel of the image and checked
	# against it; then the work pkg -r leaves undone in the stage: the
	# deferred triggers, the caches and the group of the dbus launch
	# helper; then the Xspice configuration of xf86-video-qxl, the
	# package cache and the debug files come out of the stage
	log '  [4a] kmod rebuild + kmod/kernel match, package triggers in the stage, Xspice config, package cache, debug files'
	if [ "$DRY" -eq 1 ]; then
		printf '    + every package owning a .ko whose FreeBSD_version is not __FreeBSD_version of %s/sys/sys/param.h: make -C %s/<origin> SRC_BASE=%s OSVERSION=<it> BATCH=yes DISABLE_VULNERABILITIES=yes PACKAGES=%s/kmod-packages clean package; pkg -r %s add -f; pkg lock (KMOD_REBUILD=%s)\n' "$SRC" "$PORTS" "$SRC" "$OUT" "$STAGE" "$KMOD_REBUILD"
		printf '    + check those packages against __FreeBSD_version of %s/sys/sys/param.h (ALLOW_KMOD_MISMATCH=%s)\n' "$SRC" "$ALLOW_KMOD_MISMATCH"
		printf '    + pkg -c %s triggers (when %s/var/db/pkg/triggers holds deferred triggers)\n' "$STAGE" "$STAGE"
		printf '    + chroot %s: gdk-pixbuf-query-loaders --update-cache, glib-compile-schemas, update-mime-database (each when its tool is there and its cache is not)\n' "$STAGE"
		printf '    + chroot %s: chown root:messagebus + chmod 4750 /usr/local/libexec/dbus-daemon-launch-helper\n' "$STAGE"
		printf '    + rm %s/usr/local/etc/X11/xorg.conf.d/spiceqxl.xorg.conf\n' "$STAGE"
		printf '    + rm -rf %s/var/cache/pkg/*\n' "$STAGE"
		if [ "$KEEP_DEBUG" = yes ]; then
			printf '    + KEEP_DEBUG=yes: %s/usr/lib/debug is kept\n' "$STAGE"
		else
			printf "    + rm -rf %s/usr/lib/debug; find %s/boot -type f -name '*.debug' -exec rm -f -- {} + (KEEP_DEBUG=yes keeps them)\n" "$STAGE" "$STAGE"
		fi
	else
		rebuild_kmods "$STAGE" "$SRC"
		check_kmods "$STAGE" "$SRC"
		pkg_triggers "$STAGE"
		strip_xspice_conf "$STAGE"
		prune_stage "$STAGE"
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
