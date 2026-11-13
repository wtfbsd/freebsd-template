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
#   ALLOW_UNBRANDED_INSTALLER  yes builds the live ISO although the
#              installer-template refuses the artwork (its own look, with a
#              warning); default no: the build fails
#
# The desktop ISO is a live system (overlay/live, see [6b]): it boots the
# Xfce desktop as the user "live" with the installer open first. The
# installer comes from the installer-template, named in product.conf:
#   INSTALLER_DIR  a local checkout, copied into the build
#   INSTALLER_REF  a git ref of INSTALLER_URL, cloned into the build
# Unset, INSTALLER_REF is the installer-template's merged main (pinned in
# this file); INSTALLER_REF=none carries a stand-in launcher that runs the
# text installer in a terminal instead.

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
BRAND_URL CI_ENABLED PUBLISH_METHOD PUBLISH_TARGET PUBLISHER_ORG
INSTALLER_REF INSTALLER_URL INSTALLER_DIR PRODUCT_VERSION ARTWORK_VARIANT
ARTWORK_REF ARTWORK_SHA256 ARTWORK_PACK'
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
	INSTALLER_REF) INSTALLER_REF=$_v ;;
	INSTALLER_URL) INSTALLER_URL=$_v ;;
	INSTALLER_DIR) INSTALLER_DIR=$_v ;;
	PRODUCT_VERSION) PRODUCT_VERSION=$_v ;;
	ARTWORK_VARIANT) ARTWORK_VARIANT=$_v ;;
	ARTWORK_REF) ARTWORK_REF=$_v ;;
	ARTWORK_SHA256) ARTWORK_SHA256=$_v ;;
	ARTWORK_PACK) ARTWORK_PACK=$_v ;;
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

# the installer-template of the live desktop ISO: a local directory, or a
# git ref of a repository URL; neither means the stand-in launcher
# the merged main of the installer-template: the default INSTALLER_REF;
# INSTALLER_REF=none builds the stand-in launcher instead
INSTALLER_REF_DEFAULT=f77bb78a9a67799511f84582f855e904bdd141e7
INSTALLER_REF=${INSTALLER_REF:-}
INSTALLER_URL=${INSTALLER_URL:-https://github.com/wtfbsd/installer-template.git}
INSTALLER_DIR=${INSTALLER_DIR:-}
if [ -z "$INSTALLER_REF" ] && [ -z "$INSTALLER_DIR" ]; then
	INSTALLER_REF=$INSTALLER_REF_DEFAULT
fi
[ "$INSTALLER_REF" != none ] || INSTALLER_REF=''
[ -z "$INSTALLER_REF" ] || [ -z "$INSTALLER_DIR" ] \
	|| die 'INSTALLER_REF and INSTALLER_DIR do not go together: name one installer-template'
if [ -n "$INSTALLER_REF" ]; then
	chk '^[A-Za-z0-9_][A-Za-z0-9._/-]*$' "$INSTALLER_REF" 'INSTALLER_REF must be a git ref or commit (letters, digits, . _ / -; not starting with -)'
	chk '^(https|file)://[A-Za-z0-9._~/:@%+-]+$' "$INSTALLER_URL" 'INSTALLER_URL must be an https:// or file:// URL'
fi
case $INSTALLER_DIR in *[[:space:]]*) die "INSTALLER_DIR may not contain whitespace: $INSTALLER_DIR" ;; esac

# the artwork: a pre-rendered pack of the artwork template, by commit and
# variant, checked against its sha256 (pinned here for the template's own
# product; ARTWORK_SHA256 for any other). ARTWORK_REF=none: no branding.
ARTWORK_REF_DEFAULT=ce8e9714a2b47e3f17ff36ea647dbcc02f4399ac
ARTWORK_REF=${ARTWORK_REF:-$ARTWORK_REF_DEFAULT}
ARTWORK_VARIANT=${ARTWORK_VARIANT:-default}
ARTWORK_SHA256=${ARTWORK_SHA256:-}
ARTWORK_PACK=${ARTWORK_PACK:-}
ARTWORK_URL=${ARTWORK_URL:-https://github.com/wtfbsd/artwork-template/releases/download}
PRODUCT_VERSION=${PRODUCT_VERSION:-}
if [ "$ARTWORK_REF" != none ]; then
	chk '^[0-9a-f]{12,40}$' "$ARTWORK_REF" 'ARTWORK_REF must be a commit of the artwork template (12 to 40 hex digits) or none'
	chk '^[a-z][a-z0-9-]*$' "$ARTWORK_VARIANT" 'ARTWORK_VARIANT must match ^[a-z][a-z0-9-]*$'
	[ -z "$ARTWORK_SHA256" ] || chk '^[0-9a-f]{64}$' "$ARTWORK_SHA256" 'ARTWORK_SHA256 must be 64 hex digits'
	case $ARTWORK_PACK in *[[:space:]]*) die "ARTWORK_PACK may not contain whitespace: $ARTWORK_PACK" ;; esac
fi
[ -z "$PRODUCT_VERSION" ] || chk '^[0-9A-Za-z][0-9A-Za-z.+-]*$' "$PRODUCT_VERSION" 'PRODUCT_VERSION must match ^[0-9A-Za-z][0-9A-Za-z.+-]*$'

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
ALLOW_UNBRANDED_INSTALLER=${ALLOW_UNBRANDED_INSTALLER:-no}
case $ALLOW_UNBRANDED_INSTALLER in
yes | no) ;;
*) die "ALLOW_UNBRANDED_INSTALLER must be yes or no (got: $ALLOW_UNBRANDED_INSTALLER)" ;;
esac
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
	# a link is removed as a link: its target, which may be outside the
	# guard root, is never followed (neither by chflags nor by rm)
	if [ -L "$1" ]; then
		rm -f -- "$1" || die "rmrf: cannot remove the link $1"
		return 0
	fi
	[ -d "$1" ] || return 0
	# a FreeBSD stage holds files with the schg flag (the kernel, libc,
	# init): rm -rf cannot remove them, so a rebuild in the same output
	# directory failed. The flags are cleared first where chflags(1) exists.
	if command -v chflags > /dev/null 2>&1; then
		chflags -R noschg "$1" 2> /dev/null || :
	fi
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
	# lightdm.conf.d/50-@SLUG@.conf) to the slug. Every path under such
	# a name moves on its own, into a directory of the slug that may
	# already be there (usr/local/share/@SLUG@/live/@SLUG@-install.desktop
	# joins the usr/local/share/<slug> of an earlier overlay): -depth
	# visits the children of a directory before the directory itself,
	# which is empty by then and goes
	# the directories it makes are 0755 whatever the umask of the build
	find "$1" -depth -path '*@SLUG@*' | (umask 022; while IFS= read -r _sf; do
		_sf_new=$(printf %s "$_sf" | sed -e "s%@SLUG@%$DISTRO_SLUG%g")
		[ "$_sf" != "$_sf_new" ] || continue
		if [ -d "$_sf" ] && [ ! -L "$_sf" ]; then
			mkdir -p -- "$_sf_new" && rmdir -- "$_sf" || die "rename $_sf failed"
		else
			mkdir -p -- "$(dirname -- "$_sf_new")" || die "rename $_sf failed"
			mv "$_sf" "$_sf_new" || die "rename $_sf failed"
		fi
	done)
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

stage_ldconfig() { # stage_ldconfig <stage> — build the ld-elf hints of the stage
	# a fresh stage has no /var/run/ld-elf.so.hints until rc.d/ldconfig
	# runs at boot, so a tool run in it with chroot does not find the
	# libraries of /usr/local/lib ("Shared object libglib-2.0.so.0 not
	# found"). This runs ldconfig -elf in the stage over /lib, /usr/lib,
	# /usr/local/lib and the directories that the packages list in the
	# stage's /usr/local/libdata/ldconfig/* (one per line; a line that is
	# not an absolute path or names a directory missing from the stage is
	# skipped), as rc.d/ldconfig does. Each directory is one argument of
	# the chroot command; nothing read from the stage goes through a shell.
	_lst=$1
	set -- /lib /usr/lib /usr/local/lib
	for _lf in "$_lst"/usr/local/libdata/ldconfig/*; do
		[ -f "$_lf" ] || continue
		while IFS= read -r _ld || [ -n "$_ld" ]; do
			case $_ld in
			/*) if [ -d "$_lst$_ld" ]; then set -- "$@" "$_ld"; fi ;;
			esac
		done < "$_lf"
	done
	chroot "$_lst" /sbin/ldconfig -elf "$@" || die "chroot $_lst /sbin/ldconfig -elf $* failed"
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
	# the trigger and cache tools need the hints of the stage first
	stage_ldconfig "$1"
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
	pkg -r "$1" query '%At %Av' "$2" | k="$3" awk '$1 == ENVIRON["k"] { print $2; exit }'
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
		_pv=$(printf '%s' "$KMOD_MM" | n="$_n" awk '$1 == ENVIRON["n"] { print $2; exit }')
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
	_bad=$(printf '%s' "$KMOD_MM" | k="$_kv" awk '{ printf "\n  %s: built for %s, kernel is %s", $1, $2, ENVIRON["k"] }')
	[ -n "$_bad" ] || return 0
	if [ "$ALLOW_KMOD_MISMATCH" = yes ]; then
		printf '%s\n' "WARNING: kmod packages do not match the kernel (__FreeBSD_version $_kv of $2); ALLOW_KMOD_MISMATCH=yes, building anyway:$_bad" >&2
		return 0
	fi
	die "kmod packages do not match the kernel (__FreeBSD_version $_kv of $2):$_bad
KMOD_REBUILD=yes rebuilds them from the ports tree; ALLOW_KMOD_MISMATCH=yes builds anyway"
}

fetch_installer() { # fetch_installer <dir> — the installer-template, into <dir>
	# INSTALLER_DIR is copied; INSTALLER_REF is cloned from INSTALLER_URL
	# and checked out. Either way the tree must have install-into-stage.sh.
	_fi=$1
	rmrf "$_fi" "$OUT"
	if [ -n "$INSTALLER_DIR" ]; then
		[ -d "$INSTALLER_DIR" ] || die "INSTALLER_DIR: no such directory: $INSTALLER_DIR"
		cp -R "$INSTALLER_DIR" "$_fi" || die "cannot copy $INSTALLER_DIR to $_fi"
	else
		command -v git > /dev/null 2>&1 || die 'INSTALLER_REF needs git (pkg install git-lite)'
		git clone -q -- "$INSTALLER_URL" "$_fi" || die "git clone $INSTALLER_URL failed"
		# a commit or a tag, or a branch of the remote
		git -C "$_fi" -c advice.detachedHead=false checkout -q --detach "$INSTALLER_REF" 2> /dev/null \
			|| git -C "$_fi" -c advice.detachedHead=false checkout -q --detach "origin/$INSTALLER_REF" \
			|| die "git checkout $INSTALLER_REF of $INSTALLER_URL failed"
	fi
	[ -f "$_fi/install-into-stage.sh" ] \
		|| die "the installer-template ${INSTALLER_DIR:-$INSTALLER_REF} has no install-into-stage.sh"
}

# The live layer of the desktop ISO (overlay/live). The raw image [6] is
# written before any of it reaches the stage, and every path it adds is
# taken out again after the ISO [7], so the installed system never has the
# live user, the autologin or the installer autostart.
#
#   overlay/live/rootfs   copied over the stage (outside /etc)
#   overlay/live/etc      copied over a COPY of the stage's /etc, which
#                         goes into the ISO as /conf/base/etc.cpio.gz
#
# The root of the ISO is cd9660, read-only. rc(8) runs the stock
# rc.initdiskless when /etc/diskless exists: it mounts a memory disk on
# /etc, /var, /root and /home and unpacks /conf/base/<dir>.cpio.gz into
# each, before any rc.d script runs (the same mechanism as NanoBSD and
# diskless(8) machines). /tmp gets its memory disk from rc.d/tmp.
LIVE_BACKUP=''
# the one command the live user may run as root (doas.conf of the ISO)
LIVE_APPLY=/usr/local/libexec/wtfbsd-installer/installer-apply

live_snapshot() { # live_snapshot <stage> <file> — every path of the stage, sorted
	(cd "$1" && find . -print) > "$2.unsorted" || die "find $1 failed"
	LC_ALL=C sort "$2.unsorted" > "$2" || die "sort of the paths of $1 failed"
	rm -f "$2.unsorted"
}

live_backup() { # live_backup <stage> <relpath> — keep a staged file the live layer changes
	[ -f "$1/$2" ] && [ ! -L "$1/$2" ] || return 0
	mkdir -p "$LIVE_BACKUP/$(dirname -- "$2")" || die "cannot create the backup of $2"
	cp -p "$1/$2" "$LIVE_BACKUP/$2" || die "cannot keep a copy of $1/$2"
}

live_md_size() { # live_md_size <dir> — the size of the memory disk for <dir>
	# twice what the stage holds, plus 256 MiB of room, in KiB (mdmfs -s)
	_k=$(du -sk "$1" 2> /dev/null | awk '{ print $1 }')
	case $_k in '' | *[!0-9]*) _k=0 ;; esac
	printf '%sk\n' $((_k * 2 + 262144))
}

live_stage() { # live_stage <stage> <work dir> — add the live layer for the ISO
	_ls=$1 _lw=$2
	_lr="$ROOT/overlay/live/rootfs"
	_le="$ROOT/overlay/live/etc"
	[ -d "$_lr" ] && [ -d "$_le" ] || die "missing the live layer $ROOT/overlay/live/{rootfs,etc}"
	LIVE_BACKUP="$_lw/.live-backup"
	rmrf "$LIVE_BACKUP" "$OUT"
	rmrf "$_lw/live-conf" "$OUT"
	mkdir -p "$LIVE_BACKUP" "$_lw/live-conf"
	live_snapshot "$_ls" "$_lw/.live-before"
	# every staged file the layer replaces is kept, and the motd and
	# doas.conf, which the ISO changes in place
	(cd "$_lr" && find . -type f) | sed -e 's|^\./||' -e "s%@SLUG@%$DISTRO_SLUG%g" > "$_lw/.live-files" \
		|| die "cannot list $_lr"
	while IFS= read -r _lf; do
		live_backup "$_ls" "$_lf"
	done < "$_lw/.live-files"
	live_backup "$_ls" usr/local/etc/doas.conf
	live_backup "$_ls" etc/motd
	# 1. the layer outside /etc, like the base and profile overlays
	cp -Rp "$_lr/." "$_ls/" || die "cannot copy $_lr"
	subst_overlay "$_ls" "$_lr"
	rename_slug "$_ls" || die 'the @SLUG@ rename of the live layer failed'
	own_overlay "$_ls" "$_lr"
	# 2. the front ends of the installer (GTK, text) run as the live user;
	#    the one thing it may run as root is the installer's GTK-free
	#    helper, with the environment doas resets (no keepenv, no setenv):
	#    a GUI running as root on the user's display would load modules
	#    the user controls (XSETTINGS, GTK_MODULES)
	{
		printf '# live ISO only (build.sh [6b]): the one root command of the live user\n'
		printf 'permit nopass live as root cmd %s\n' "$LIVE_APPLY"
	} >> "$_ls/usr/local/etc/doas.conf" || die "cannot write $_ls/usr/local/etc/doas.conf"
	# 3. the installer-template (it replaces the stand-in launcher), with
	#    the product's installer.conf, the artwork (palette, sources) and
	#    the catalogue of the licensed software
	if [ -n "$INST_TREE" ]; then
		{
			printf 'PRODUCT_NAME=%s\nPRODUCT_SLUG=%s\nOS=freebsd\n' "$DISTRO_NAME" "$DISTRO_SLUG"
			printf 'DEFAULT_KEYMAP=us\nDEFAULT_TZ=UTC\nMIN_DISK_GB=16\n'
			# rc.d/live_session names the medium of the live system in
			# /var/run/wtfbsd-live-medium early in the boot: a live root in
			# memory that does not name it offers no disk
			printf 'LIVE_MEDIUM_REQUIRED=yes\n'
		} > "$_lw/installer.conf" || die "cannot write $_lw/installer.conf"
		set -- --conf "$_lw/installer.conf"
		# the installer's look comes from the artwork; install-into-stage.sh
		# checks its palette with python3 on the build host
		if [ -n "${ART:-}" ]; then
			if command -v python3 > /dev/null 2>&1; then
				set -- "$@" --artwork "$ART"
			else
				printf '%s\n' "WARNING: no python3 on the build host: the installer keeps its own look (install-into-stage.sh --artwork needs it)" >&2
			fi
		fi
		if ! sh "$INST_TREE/install-into-stage.sh" "$_ls" "$@"; then
			# the artwork is the one argument the installer may not take
			# (a palette it does not know): once more without it, loudly
			case " $*:$ALLOW_UNBRANDED_INSTALLER " in
			*' --artwork '*':yes ')
				printf '%s\n' "WARNING: the installer-template could not use the artwork $ART: it keeps its own look (ALLOW_UNBRANDED_INSTALLER=yes)" >&2
				sh "$INST_TREE/install-into-stage.sh" "$_ls" --conf "$_lw/installer.conf" \
					|| die "$INST_TREE/install-into-stage.sh $_ls failed"
				;;
			*' --artwork '*) die "$INST_TREE/install-into-stage.sh $_ls failed: the installer-template cannot use the artwork $ART (ALLOW_UNBRANDED_INSTALLER=yes builds an installer with its own look)" ;;
			*) die "$INST_TREE/install-into-stage.sh $_ls failed" ;;
			esac
		fi
		if [ -f "$_ls/usr/local/share/$DISTRO_SLUG/licensed-software.json" ]; then
			mkdir -p "$_ls/usr/local/libexec/wtfbsd-installer/licences" \
				&& cp "$_ls/usr/local/share/$DISTRO_SLUG/licensed-software.json" \
					"$_ls/usr/local/libexec/wtfbsd-installer/licences/licensed-software.json" \
				|| die 'cannot give the installer the catalogue of the licensed software'
		fi
		[ -x "$_ls/usr/local/bin/wtfbsd-installer" ] \
			|| die "install-into-stage.sh left no launcher $_ls/usr/local/bin/wtfbsd-installer"
		[ -x "$_ls$LIVE_APPLY" ] || die "install-into-stage.sh left no root helper $_ls$LIVE_APPLY"
	fi
	# 4. the live /etc: a copy of the stage's, with the live rc.d script
	#    and rc.conf.d fragments, and the text installer on ttyu0
	_lc="$_lw/live-conf"
	cp -Rp "$_ls/etc" "$_lc/etc" || die "cannot copy $_ls/etc"
	cp -Rp "$_le/." "$_lc/etc/" || die "cannot copy $_le"
	subst_overlay "$_lc/etc" "$_le"
	own_overlay "$_lc/etc" "$_le"
	sed -E 's|^(ttyu0[[:space:]]+)"[^"]*"|\1"/usr/libexec/getty live.tui"|' "$_lc/etc/ttys" > "$_lc/ttys.new" \
		&& cat "$_lc/ttys.new" > "$_lc/etc/ttys" && rm -f "$_lc/ttys.new" || die 'cannot write the live /etc/ttys'
	grep -Eq '^ttyu0[[:space:]]+"/usr/libexec/getty live.tui"' "$_lc/etc/ttys" \
		|| die 'the live /etc/ttys has no ttyu0 line to give the text installer'
	printf '\n# live ISO only (build.sh [6b]): the text installer on the serial console\nlive.tui:\\\n\t:al=root:lo=/usr/local/libexec/%s/live-tui:tc=3wire:\n' \
		"$DISTRO_SLUG" >> "$_lc/etc/gettytab" || die 'cannot write the live /etc/gettytab'
	# the stage's fstab is the one of the raw image (a UFS root line):
	# mkisoimages.sh writes the cd9660 line into the stage only while it
	# packs the ISO, and mount -a would try to remount / from it
	printf '/dev/iso9660/%s\t/\tcd9660\tro\t0\t0\n' "$VOL" > "$_lc/etc/fstab" \
		|| die 'cannot write the live /etc/fstab'
	mkdir -p "$_lc/home"
	# 5. the archives rc.initdiskless unpacks, and the size of each
	#    memory disk. The name must end in .cpio.gz for rc.initdiskless;
	#    it unpacks them with tar(1), which reads either format.
	mkdir -p "$_ls/conf/base" || die "cannot create $_ls/conf/base"
	for _ld in etc var root home; do
		mkdir -p "$_ls/conf/base/$_ld"
		case $_ld in
		etc | home) _lsrc=$_lc ;;
		*) _lsrc=$_ls ;;
		esac
		case $_ld in
		home) printf '1g\n' > "$_ls/conf/base/$_ld/md_size" ;;
		*) live_md_size "$_lsrc/$_ld" > "$_ls/conf/base/$_ld/md_size" ;;
		esac
		(cd "$_lsrc" && tar -czf "$_ls/conf/base/$_ld.cpio.gz" "$_ld") \
			|| die "cannot write $_ls/conf/base/$_ld.cpio.gz"
	done
	# 6. the mount point of /home and the switch for rc.initdiskless
	[ -d "$_ls/home" ] || mkdir "$_ls/home" || die "cannot create $_ls/home"
	: > "$_ls/etc/diskless" || die "cannot create $_ls/etc/diskless"
	return 0
}

live_manifest() { # live_manifest <stage> <work dir> <install dir> <system KiB>
	# what a copy install needs to copy the system from the ISO's root and
	# leave the live layer behind: every path the layer added (the install
	# directory itself among them), the originals of the files it replaced,
	# the name of the root pool and the size of the system
	_ms=$1 _mw=$2 _mi=$3
	live_snapshot "$_ms" "$_mw/.live-mid"
	LC_ALL=C comm -13 "$_mw/.live-before" "$_mw/.live-mid" > "$_mw/.live-paths" \
		|| die 'cannot list the paths of the live layer'
	# the install command reads the list with bsdtar -X, which matches a
	# pattern at any component of a path ("./conf" drops every conf/ of
	# the system) unless it starts with ^; the glob characters are escaped
	sed -e 's/[][*?$\\]/\\&/g' -e 's/^/^/' "$_mw/.live-paths" > "$_mi/live-paths" \
		|| die 'cannot anchor the paths of the live layer'
	rm -f "$_mw/.live-mid" "$_mw/.live-paths"
	mkdir -p "$_mi/orig" || die "cannot create $_mi/orig"
	cp -Rp "$LIVE_BACKUP/." "$_mi/orig/" || die "cannot copy the originals to $_mi/orig"
	# mkisoimages.sh writes the cd9660 root line into the stage's fstab
	# while it packs the ISO: the installed system gets the image's own
	mkdir -p "$_mi/orig/etc" && cp -p "$_ms/etc/fstab" "$_mi/orig/etc/fstab" \
		|| die "cannot keep the fstab of the image"
	printf '%s\n' "$ROOT_POOL" > "$_mi/system.pool"
	printf '%s\n' "$4" > "$_mi/system.kb"
}

live_revert() { # live_revert <stage> <work dir> — take the live layer out again
	_rs=$1 _rw=$2
	[ -f "$_rw/.live-before" ] || die "live_revert: no snapshot $_rw/.live-before"
	live_snapshot "$_rs" "$_rw/.live-after"
	# the paths the layer added, the deepest first
	LC_ALL=C comm -13 "$_rw/.live-before" "$_rw/.live-after" | LC_ALL=C sort -r > "$_rw/.live-new" \
		|| die 'cannot compare the paths of the stage'
	while IFS= read -r _rp; do
		_rt="$_rs/${_rp#./}"
		# a symlink the layer added is removed itself, never followed:
		# only the directory it is in has to be in the stage
		if [ -L "$_rt" ]; then
			in_stage "$_rs" "$(dirname -- "$_rt")"
		else
			in_stage "$_rs" "$_rt"
		fi
		if [ -d "$_rt" ] && [ ! -L "$_rt" ]; then
			rmdir -- "$_rt" || die "cannot remove $_rt"
		else
			rm -f -- "$_rt" || die "cannot remove $_rt"
		fi
	done < "$_rw/.live-new"
	# the files it replaced come back
	(cd "$LIVE_BACKUP" && find . -type f) | sed 's|^\./||' > "$_rw/.live-kept" || die "cannot list $LIVE_BACKUP"
	while IFS= read -r _rf; do
		in_stage "$_rs" "$_rs/$_rf"
		cp -p "$LIVE_BACKUP/$_rf" "$_rs/$_rf" || die "cannot restore $_rs/$_rf"
	done < "$_rw/.live-kept"
	rmrf "$LIVE_BACKUP" "$OUT"
	rmrf "$_rw/live-conf" "$OUT"
	rm -f "$_rw/.live-before" "$_rw/.live-after" "$_rw/.live-new" "$_rw/.live-kept" "$_rw/.live-files"
	return 0
}

artwork_pinned_sha() { # artwork_pinned_sha <pack name> — the pinned sha256, or nothing
	case $1 in
	examplebsd-ce8e9714a2b4-default) echo cf0b37d9a793f8f16cc78f2a82122fac28087253cc27cac384357fd6a6d85ce7 ;;
	examplebsd-ce8e9714a2b4-cyberpunk) echo fd02f48114c0e969ed92584953062da72b1923c759b0dff2701fd201cc248669 ;;
	esac
}

sha256_of() { # sha256_of <file>
	if command -v sha256 > /dev/null 2>&1; then sha256 -q "$1"; else sha256sum "$1" | cut -d' ' -f1; fi
}

ART=''
fetch_artwork() { # fetch_artwork — the pack into $OUT/artwork, checked; sets ART
	_an="$DISTRO_SLUG-$(printf %s "$ARTWORK_REF" | cut -c1-12)-$ARTWORK_VARIANT"
	_aw="$OUT/artwork"
	rmrf "$_aw" "$OUT"
	mkdir -p "$_aw" || die "cannot create $_aw"
	_af="$_aw/$_an.tar.xz"
	if [ -n "$ARTWORK_PACK" ]; then
		cp "$ARTWORK_PACK" "$_af" || die "cannot copy the artwork pack $ARTWORK_PACK"
	else
		_au="$ARTWORK_URL/pack-$(printf %s "$ARTWORK_REF" | cut -c1-12)/$_an.tar.xz"
		if command -v fetch > /dev/null 2>&1; then
			fetch -q -o "$_af" "$_au" || die "fetch $_au failed"
		else
			curl -fsSL -o "$_af" "$_au" || die "curl $_au failed"
		fi
	fi
	_want=${ARTWORK_SHA256:-$(artwork_pinned_sha "$_an")}
	[ -n "$_want" ] || die "no sha256 for the artwork pack $_an: set ARTWORK_SHA256 (the pack's .sha256 file)"
	_have=$(sha256_of "$_af")
	[ "$_have" = "$_want" ] || die "the artwork pack $_an has sha256 $_have, not the pinned $_want: refusing it"
	tar -xJf "$_af" -C "$_aw" || die "cannot unpack $_af"
	ART="$_aw/$_an"
	[ -f "$ART/branding/spots.tsv" ] && [ -d "$ART/out" ] || die "the artwork pack $_an has no branding/spots.tsv or out/"
	grep -qx "name=$DISTRO_SLUG" "$ART/PACK" && grep -qx "variant=$ARTWORK_VARIANT" "$ART/PACK" \
		|| die "the artwork pack $_an is not for $DISTRO_SLUG / $ARTWORK_VARIANT (its PACK file)"
}

spots_freebsd() { # spots_freebsd <spots.tsv> — "spot<TAB>supported|no" for every row
	# the columns are read by the names of the header row; a missing
	# column fails the build
	awk -F '\t' '
		NR == 1 {
			for (i = 1; i <= NF; i++) col[$i] = i
			if (!("spot" in col) || !("freebsd" in col) || !("rendered" in col)) {
				print "MISSING-COLUMN"; exit 1
			}
			next
		}
		$0 == "" { next }
		{
			f = $(col["freebsd"])
			ok = (f ~ /^n\/a/ || f ~ /^check/ || f == "" || f == "-") ? "no" : "supported"
			print $(col["spot"]) "\t" ok
		}' "$1"
}

stamp_identity() { # stamp_identity <stage> <in.png> <out.png> [bottom px]
	set -- "$1" "$2" "$3" "${4:-0}"
	_sf=''
	# the font: the family of the palette when the build host has fontconfig,
	# else the DejaVu Sans file of the stage itself
	if ! command -v fc-match > /dev/null 2>&1 && [ -f "$1/usr/local/share/fonts/dejavu/DejaVuSans.ttf" ]; then
		_sf="$1/usr/local/share/fonts/dejavu/DejaVuSans.ttf"
	fi
	mkdir -p "$(dirname -- "$3")"
	if [ -n "$_sf" ]; then
		sh "$ART/scripts/identity-stamp.sh" --palette "$ART/palette.env" --variant "$ARTWORK_VARIANT" \
			--font "$_sf" --bottom "$4" "$1/usr/local/share/$DISTRO_SLUG/identity" "$2" "$3" > /dev/null
	else
		sh "$ART/scripts/identity-stamp.sh" --palette "$ART/palette.env" --variant "$ARTWORK_VARIANT" \
			--bottom "$4" "$1/usr/local/share/$DISTRO_SLUG/identity" "$2" "$3" > /dev/null
	fi || die "identity-stamp.sh $2 failed"
}

brand_identity() { # brand_identity <stage> — /usr/local/share/<slug>/identity
	_bs=$1
	_ver=${PRODUCT_VERSION:-$(date -u +%Y.%m)}
	_build=''
	[ -n "$PRODUCT_VERSION" ] || _build=$(date -u +%Y-%m-%d)
	# the base: the release of the userland that was built (freebsd-version
	# of the stage reads it from the built world, not from this host)
	_rel=$(sh "$_bs/bin/freebsd-version" -u 2> /dev/null)
	[ -n "$_rel" ] || die "cannot read the release of the stage ($_bs/bin/freebsd-version -u)"
	_lab=$(printf '%s' "$ARTWORK_VARIANT" | awk '{ print toupper(substr($0, 1, 1)) substr($0, 2) }')
	mkdir -p "$_bs/usr/local/share/$DISTRO_SLUG"
	sh "$ART/scripts/identity-file.sh" --product "$DISTRO_NAME" --version "$_ver" --base "FreeBSD $_rel" \
		--variant "$_lab" --arch "$DISTRO_ARCH" ${_build:+--build "$_build"} \
		> "$_bs/usr/local/share/$DISTRO_SLUG/identity" || die 'identity-file.sh failed'
}

brand_spot() { # brand_spot <stage> <profile> <spot> — install one branding spot
	_bs=$1 _bp=$2 _o="$ART/out" _sl=$DISTRO_SLUG
	case $3 in
	identity-file) brand_identity "$_bs" ;;
	loader-brand)
		mkdir -p "$_bs/boot/lua" "$_bs/boot/images"
		cp "$_o/boot/freebsd/gfx-$_sl.lua" "$_bs/boot/lua/gfx-$_sl.lua" \
			&& cp "$_o/loader/$_sl-brand.png" "$_bs/boot/images/$_sl-brand.png" || return 1
		;;
	loader-logo)
		mkdir -p "$_bs/boot/images"
		cp "$_o/loader/$_sl-logo.png" "$_bs/boot/images/$_sl-logo.png" || return 1
		;;
	loader-menu-title | boot-splash)
		mkdir -p "$_bs/boot/loader.conf.d" "$_bs/boot/images"
		cp "$_o/boot/freebsd/loader.conf.fragment" "$_bs/boot/loader.conf.d/$_sl-brand.conf" \
			&& cp "$_o/loader/splash.png" "$_bs/boot/images/$_sl-splash.png" || return 1
		;;
	motd)
		# the artwork's text, then the product's own line
		{ cat "$_o/console/motd.template" && printf '%s\n' "$MOTD"; } > "$_bs/etc/motd.template" \
			&& cp "$_bs/etc/motd.template" "$_bs/etc/motd" || return 1
		;;
	login-issue)
		cp "$_o/console/issue" "$_bs/etc/issue" || return 1
		_im=$(sed -n 's/^[[:space:]]*:im=\(.*\):$/\1/p' "$_o/console/gettytab.fragment" | head -n 1)
		[ -n "$_im" ] || return 1
		_im=$(printf '%s' "$_im" | sed -e 's/[\\&|]/\\&/g')
		sed -e "/^default:/,/[^\\\\]\$/ s|:im=[^:]*:|:im=$_im:|" "$_bs/etc/gettytab" > "$_bs/etc/gettytab.new" \
			&& cat "$_bs/etc/gettytab.new" > "$_bs/etc/gettytab" && rm -f "$_bs/etc/gettytab.new" || return 1
		;;
	lightdm-background)
		[ "$_bp" = desktop ] || return 0
		stamp_identity "$_bs" "$_o/lightdm/greeter-1920x1080.png" \
			"$_bs/usr/local/share/$_sl/lightdm/greeter-1920x1080.png"
		;;
	lightdm-theme)
		[ "$_bp" = desktop ] || return 0
		mkdir -p "$_bs/usr/local/etc/lightdm" "$_bs/usr/local/share/themes/$_sl-greeter/gtk-3.0"
		cp "$_o/lightdm/lightdm-gtk-greeter.conf" "$_bs/usr/local/etc/lightdm/lightdm-gtk-greeter.conf" \
			&& cp "$_o/lightdm/greeter-gtk.css" "$_bs/usr/local/share/themes/$_sl-greeter/gtk-3.0/gtk.css" || return 1
		;;
	xdm-logo)
		[ "$_bp" = desktop ] || return 0
		mkdir -p "$_bs/usr/local/share/$_sl/dm/pixmaps"
		cp "$_o/dm/pixmaps/"*.xpm "$_bs/usr/local/share/$_sl/dm/pixmaps/" || return 1
		;;
	xdm-colours)
		[ "$_bp" = desktop ] || return 0
		mkdir -p "$_bs/usr/local/etc/X11/xdm"
		cp "$_o/dm/xdm/Xresources" "$_o/dm/xdm/Xsetup_0" "$_bs/usr/local/etc/X11/xdm/" || return 1
		;;
	installer-header | installer-sidebar)
		[ "$_bp" = desktop ] || return 0
		mkdir -p "$_bs/usr/local/share/$_sl/installer"
		cp "$_o/installer/${3#installer-}.png" "$_bs/usr/local/share/$_sl/installer/" || return 1
		;;
	installer-palette)
		[ "$_bp" = desktop ] || return 0
		mkdir -p "$_bs/usr/local/share/$_sl/xfce"
		cp "$_o/xfce/gtk-colors.css" "$_bs/usr/local/share/$_sl/xfce/gtk-colors.css" || return 1
		;;
	installer-name)
		# the installer takes its title from its installer.conf
		# (PRODUCT_NAME); bsdinstall, which reads OSNAME, is not used
		:
		;;
	wallpapers)
		[ "$_bp" = desktop ] || return 0
		for _w in "$_o/wallpapers/"wallpaper-*.png; do
			# the stamp keeps the 30 px bottom panel clear
			stamp_identity "$_bs" "$_w" "$_bs/usr/local/share/$_sl/wallpapers/${_w##*/}" 30
		done
		mkdir -p "$_bs/usr/local/etc/xdg/xfce4/xfconf/xfce-perchannel-xml"
		# xfdesktop 4.20 keys the backdrop by the output's name; the scfb
		# and vesa drivers call theirs "default", which the pack does not
		# list: the first backdrop of the pack is given to it as well
		awk '
			/<property name="monitordefault"/ { have = 1 }
			{ line[++n] = $0 }
			!img && /name="last-image"/ { img = $0 }
			!sty && /name="image-style"/ { sty = $0 }
			END {
				for (i = 1; i <= n; i++) {
					print line[i]
					if (!have && img != "" && line[i] ~ /<property name="screen0" type="empty">/) {
						sub(/^[ \t]*/, "", img); sub(/^[ \t]*/, "", sty)
						print "      <property name=\"monitordefault\" type=\"empty\">"
						print "        <property name=\"workspace0\" type=\"empty\">"
						print "          " img
						if (sty != "") print "          " sty
						print "        </property>"
						print "      </property>"
					}
				}
			}' "$_o/xfce/xfconf/xfce4-desktop.xml" > "$_bs/usr/local/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml" \
			|| return 1
		;;
	icon-distributor | icon-menu | icon-installer)
		[ "$_bp" = desktop ] || return 0
		mkdir -p "$_bs/usr/local/share/icons"
		cp -R "$_o/icons/hicolor" "$_bs/usr/local/share/icons/" || return 1
		;;
	xfce-theme)
		[ "$_bp" = desktop ] || return 0
		mkdir -p "$_bs/usr/local/etc/xdg/xfce4/xfconf/xfce-perchannel-xml" "$_bs/usr/local/share/themes/$DISTRO_NAME/xfwm4"
		cp "$_o/xfce/xfconf/xfce4-panel.xml" "$_o/xfce/xfconf/xsettings.xml" \
			"$_bs/usr/local/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/" \
			&& cp "$_o/xfce/xfwm4-themerc" "$_bs/usr/local/share/themes/$DISTRO_NAME/xfwm4/themerc" || return 1
		;;
	identity-line)
		# drawn by lightdm-background and wallpapers (the stamp)
		:
		;;
	*) return 2 ;;
	esac
}

# slug_replace <from> <to> <in> <out> — copy <in> to <out>, with every
# literal occurrence of <from> replaced by <to>. The two are strings, not
# regular expressions: the name of a pack is data.
slug_replace() { # slug_replace <from> <to> <in> <out>
	[ -n "${1:-}" ] || die 'slug_replace: the string to replace is empty'
	awk -v a="$1" -v b="$2" '
		function rep(s,   i, out) {
			out = ""
			while ((i = index(s, a)) > 0) {
				out = out substr(s, 1, i - 1) b
				s = substr(s, i + length(a))
			}
			return out s
		}
		{ print rep($0) }
	' "$3" > "$4" || die "cannot write $4"
}

# The wallpaper helper of the artwork pack: an autostart entry of the Xfce
# session and the script it runs, which fills in the wallpaper on every
# output that has none yet. The Xfce of FreeBSD reads its autostart entries
# from /usr/local/etc/xdg/autostart. The paths are fixed:
#   /usr/local/etc/xdg/autostart/<slug>-wallpaper.desktop       (0644)
#   /usr/local/share/<slug>/xfce/session/<slug>-wallpaper.sh    (0755)
# The Exec= line of the entry is written here, so it always names the
# script that is installed, whatever the slug of the pack is.
#
# install_wallpaper <stage> <pack root> — the pack holds the two files as
# out/xfce/autostart/<packslug>-wallpaper.desktop and
# out/xfce/session/<packslug>-wallpaper.sh (<packslug>: name= of PACK).
install_wallpaper() { # install_wallpaper <stage> <pack root>
	_sw=$1
	_sp=$2
	_sl=$DISTRO_SLUG
	[ -f "$_sp/PACK" ] || die "the artwork pack has no PACK file ($_sp)"
	_ps=$(sed -n 's/^name=//p' "$_sp/PACK" | head -n 1)
	chk '^[a-z0-9][a-z0-9-]*$' "$_ps" 'the name of the artwork pack is not a slug'
	_sd="$_sp/out/xfce/autostart/$_ps-wallpaper.desktop"
	_ss="$_sp/out/xfce/session/$_ps-wallpaper.sh"
	_hd=no
	if [ -e "$_sd" ] || [ -L "$_sd" ]; then _hd=yes; fi
	_hs=no
	if [ -e "$_ss" ] || [ -L "$_ss" ]; then _hs=yes; fi
	# a pack of an older artwork template ships no helper
	[ "$_hd$_hs" != nono ] || return 0
	[ "$_hd" = yes ] || die "the artwork pack holds the session helper of the wallpaper but no autostart entry: ship both $_sd and $_ss, or neither"
	[ "$_hs" = yes ] || die "the artwork pack holds the autostart entry of the wallpaper but no session helper: ship both $_sd and $_ss, or neither"
	# a link in the pack can name a file outside the pack: refused, not
	# followed, on every directory of the path inside the pack as well
	for _wl in out out/xfce out/xfce/autostart out/xfce/session; do
		[ ! -L "$_sp/$_wl" ] || die "the wallpaper helper of the pack is reached through a link ($_sp/$_wl)"
	done
	[ ! -L "$_sd" ] || die "the autostart entry of the wallpaper of the pack is a link ($_sd)"
	[ ! -L "$_ss" ] || die "the session helper of the wallpaper of the pack is a link ($_ss)"
	# a FIFO or a device would block or mislead the copy
	[ -f "$_sd" ] || die "the autostart entry of the wallpaper of the pack is not a regular file ($_sd)"
	[ -f "$_ss" ] || die "the session helper of the wallpaper of the pack is not a regular file ($_ss)"
	_ddst="$_sw/usr/local/etc/xdg/autostart/$_sl-wallpaper.desktop"
	_sdst="$_sw/usr/local/share/$_sl/xfce/session/$_sl-wallpaper.sh"
	mkdir -p "$_sw/usr/local/etc/xdg/autostart" "$_sw/usr/local/share/$_sl/xfce/session" \
		|| die 'cannot create the directories of the wallpaper helper'
	slug_replace "$_ps" "$_sl" "$_sd" "$_ddst"
	_exec="Exec=/bin/sh \"/usr/local/share/$_sl/xfce/session/$_sl-wallpaper.sh\""
	awk -v e="$_exec" '
		/^Exec=/ { if (!done) { print e; done = 1 } next }
		{ print }
		END { if (!done) print e }
	' "$_ddst" > "$_ddst.new" && mv "$_ddst.new" "$_ddst" \
		|| die 'cannot write the autostart entry of the wallpaper'
	slug_replace "$_ps" "$_sl" "$_ss" "$_sdst"
	chmod 0644 "$_ddst" && chmod 0755 "$_sdst" || die 'cannot set the modes of the wallpaper helper'
}

brand_stage() { # brand_stage <stage> <profile> — every spot the artwork marks supported on FreeBSD
	_bt=$(spots_freebsd "$ART/branding/spots.tsv") || die "$ART/branding/spots.tsv: a column is missing (spot, freebsd, rendered)"
	# the identity file first: the stamps read it
	brand_spot "$1" "$2" identity-file
	printf '%s\n' "$_bt" | while IFS="$(printf '\t')" read -r _spot _sup; do
		[ "$_sup" = supported ] || continue
		[ "$_spot" != identity-file ] || continue
		_brc=0
		brand_spot "$1" "$2" "$_spot" || _brc=$?
		case $_brc in
		0) ;;
		2) die "the artwork marks the spot $_spot supported on FreeBSD and this template does not install it" ;;
		*) die "installing the branding spot $_spot failed" ;;
		esac
	done || exit 1
	# the desktop (and the live session built from its stage) fills in the
	# wallpaper on every output with the pack's helper
	[ "$2" != desktop ] || install_wallpaper "$1" "$ART"
	if [ -x "$1/usr/local/bin/gtk-update-icon-cache" ] && [ -z "${PKG_ABI:-}" ]; then
		chroot "$1" /usr/local/bin/gtk-update-icon-cache -q -f /usr/local/share/icons/hicolor \
			|| die 'gtk-update-icon-cache in the stage failed'
	fi
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

# the installer-template of the live desktop ISO is fetched before hours
# of buildworld, so that a bad ref or a missing directory fails at once
INST_TREE=''
case $PROF in
desktop | both)
	if [ -n "$INSTALLER_DIR" ] || [ -n "$INSTALLER_REF" ]; then
		INST_TREE="$OUT/installer-template"
		if [ "$DRY" -eq 1 ]; then
			if [ -n "$INSTALLER_DIR" ]; then
				printf '    + cp -R %s %s\n' "$INSTALLER_DIR" "$INST_TREE"
			else
				printf '    + git clone %s %s; git checkout --detach %s\n' "$INSTALLER_URL" "$INST_TREE" "$INSTALLER_REF"
			fi
		else
			fetch_installer "$INST_TREE"
		fi
	fi
	;;
esac

# the artwork pack, fetched and checked before buildworld as well
if [ "$ARTWORK_REF" != none ]; then
	if [ "$DRY" -eq 1 ]; then
		printf '    + artwork %s-%s-%s.tar.xz from %s (sha256 checked), unpacked into %s/artwork\n' \
			"$DISTRO_SLUG" "$(printf %s "$ARTWORK_REF" | cut -c1-12)" "$ARTWORK_VARIANT" "${ARTWORK_PACK:-$ARTWORK_URL}" "$OUT"
	else
		command -v magick > /dev/null 2>&1 || command -v convert > /dev/null 2>&1 \
			|| die 'the branding stamps the identity line with ImageMagick: pkg install ImageMagick7-nox11 (or ARTWORK_REF=none)'
		fetch_artwork
	fi
fi

# --------------------------------------------------------------------------
# plan header
# --------------------------------------------------------------------------

log ''
log 'plan:'
log "  distro   $DISTRO_NAME ($DISTRO_SLUG), freebsd/$DISTRO_ARCH"
log "  rootfs   $FILESYSTEM_ROOT (pool: $ROOT_POOL, data pool: $ZDP${ZFS_POOL_NAME:+ ($ZFS_POOL_NAME)})"
log "  profile  $PROF (package set: $PACKAGE_SET, installer: $INSTALLER)"
if [ -n "$INSTALLER_DIR" ]; then
	log "  live     installer-template from $INSTALLER_DIR"
elif [ -n "$INSTALLER_REF" ]; then
	log "  live     installer-template $INSTALLER_REF of $INSTALLER_URL"
else
	log '  live     no installer-template: the stand-in launcher (text installer in a terminal)'
fi
log "  src      $SRC (unmodified; SRCCONF=$SRCCONF)"
log "  out      $OUT  (jobs: $JOBS, kernel: $KERNCONF, rootsize: $ROOTSIZE)"
if [ "$ARTWORK_REF" = none ]; then
	log '  artwork  none'
else
	log "  artwork  $ARTWORK_VARIANT of $ARTWORK_REF (version ${PRODUCT_VERSION:-the build year.month})"
fi

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
	# the EFI system partition (makefs volume label EFISYS, step [6]) on
	# /boot/efi, as the stock installer mounts it: the desktop then counts
	# it as a system mount and shows no volume icon for it; failok keeps a
	# disk without that label booting
	FSTAB_ESP=$(printf '/dev/msdosfs/EFISYS\t/boot/efi\tmsdosfs\trw,failok\t2\t2')
	if [ "$DRY" -eq 1 ]; then
		case $FILESYSTEM_ROOT in
		zfs)
			printf '    + boot/loader.conf.d/zfs.conf: zfs_load="YES"; etc/rc.conf.d/zfs: zfs_enable="YES"\n'
			printf '    + etc/fstab: %s\n' "$FSTAB_ZFS"
			;;
		*) printf '    + etc/fstab: /dev/ufs/%s-root / ufs rw 1 1\n' "$DISTRO_SLUG" ;;
		esac
		printf '    + etc/fstab: %s\n' "$FSTAB_ESP"
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
		printf '%s\n' "$FSTAB_ESP" >> "$STAGE/etc/fstab"
		mkdir -p "$STAGE/boot/efi"
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
		printf '    + chroot %s /sbin/ldconfig -elf /lib /usr/lib /usr/local/lib <the directories of %s/usr/local/libdata/ldconfig/*>\n' "$STAGE" "$STAGE"
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

	# 4b. branding: every spot of the artwork pack that FreeBSD supports
	# (branding/spots.tsv), the identity file, the identity line stamped
	# on the greeter background and the wallpapers
	if [ "$ARTWORK_REF" = none ]; then
		log '  [4b] branding: none (ARTWORK_REF=none)'
	else
		log "  [4b] branding: $ARTWORK_VARIANT of the artwork $ARTWORK_REF"
		if [ "$DRY" -eq 1 ]; then
			printf '    + identity -> %s/usr/local/share/%s/identity; every spot of branding/spots.tsv supported on FreeBSD\n' "$STAGE" "$DISTRO_SLUG"
		else
			brand_stage "$STAGE" "$p"
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
	if [ "$p" = desktop ]; then
		log '  [6b] live layer + system.img + motd hint (ISO only)'
	else
		log '  [6b] stage system.img + motd hint (ISO only)'
	fi
	if [ "$DRY" -eq 1 ]; then
		if [ "$p" = desktop ]; then
			printf '    + live layer: list every path of %s (to take the layer out after the ISO)\n' "$STAGE"
			printf '    + cp -Rp %s/overlay/live/rootfs/. %s/ (autologin of live, installer autostart, launcher, icon); keep the files it replaces\n' "$ROOT" "$STAGE"
			printf '    + append to %s/usr/local/etc/doas.conf: permit nopass live as root cmd /usr/local/libexec/wtfbsd-installer/installer-apply\n' "$STAGE"
			if [ -n "$INST_TREE" ]; then
				printf '    + sh %s/install-into-stage.sh %s\n' "$INST_TREE" "$STAGE"
			else
				printf '    + no installer-template: the stand-in launcher /usr/local/bin/wtfbsd-installer (text installer in a terminal)\n'
			fi
			printf '    + live /etc = %s/etc + %s/overlay/live/etc (rc.d/live_session); ttyu0 -> getty live.tui (text installer)\n' "$STAGE" "$ROOT"
			printf '    + %s/conf/base/{etc,var,root,home}.cpio.gz + md_size; touch %s/etc/diskless (rc.initdiskless: memory disks)\n' "$STAGE" "$STAGE"
		fi
		printf '    + mkdir -p %s; xz -c %s > %s/system.img.xz; echo %s > %s/system.fs\n' "$imgdir" "$img" "$imgdir" "$FILESYSTEM_ROOT" "$imgdir"
		printf '    + append "Install to disk: run %s-install as root" to %s/etc/motd\n' "$DISTRO_SLUG" "$STAGE"
		if [ "$p" = desktop ]; then
			printf '    + (after the ISO) rm -rf %s; restore /etc/motd; take the live layer out (every path it added; the files it replaced come back)\n' "$imgdir"
		else
			printf '    + write %s/etc/rc.local (ISO only: run the installer on the console)\n' "$STAGE"
			printf '    + (after the ISO) rm -rf %s; rm etc/rc.local; restore /etc/motd\n' "$imgdir"
		fi
	else
		# the desktop ISO is a live system: the layer goes in first, so
		# that its list of the stage's paths is the one of the raw image
		if [ "$p" = desktop ]; then
			# the size of the system, for the progress of a copy install
			_syskb=$(du -sk "$STAGE" | awk '{ print $1 }')
			live_stage "$STAGE" "$PSUB"
		fi
		mkdir -p "$imgdir"
		# xz: ISO9660 cannot hold a file over 4 GiB and the raw image is
		# mostly zeroes; the installer streams it back with xz -dc
		xz -T0 -c "$img" > "$imgdir/system.img.xz"
		# the file system of the image, for the install command's check of
		# a disk plan (it is the plan's filesystem this release installs)
		printf '%s\n' "$FILESYSTEM_ROOT" > "$imgdir/system.fs"
		cp "$STAGE/etc/motd" "$PSUB/.motd.iso"
		printf 'Install to disk: run %s-install as root.\n' "$DISTRO_SLUG" >> "$STAGE/etc/motd"
		# root is locked, so the live ISO starts the installer itself on
		# the console (like stock FreeBSD install media); ISO only. The
		# desktop ISO runs it on ttyu0 from getty instead (live layer):
		# /etc/rc.local would hold the boot, and LightDM, until it ends.
		[ "$p" = desktop ] || cat > "$STAGE/etc/rc.local" <<RCLOCAL
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
		if [ "$p" = desktop ]; then
			live_manifest "$STAGE" "$PSUB" "$imgdir" "$_syskb"
		fi
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
		if [ "$p" = desktop ]; then
			live_revert "$STAGE" "$PSUB"
		fi
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
