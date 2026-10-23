#!/bin/sh
# tests/run-tests.sh — dry-run checks for build.sh (runs on any POSIX host).
#
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
set -u
repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/wtfbsd-fbsd-tests.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT HUP INT TERM
pass=0 fail=0
ok() { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
no() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; }
conf() { # conf <name> <extra lines...>
	f="$work/$1.conf"; shift
	printf '%s\n' 'DISTRO_OS="freebsd"' 'DISTRO_NAME="ExampleBSD"' 'DISTRO_SLUG="examplebsd"' \
		'FILESYSTEM_ROOT="zfs"' 'PROFILE="both"' 'BRAND_COLOR="3b6ea5"' "$@" > "$f"
}
expect() { # expect <0|nonzero> <name> <conf>
	sh "$repo/build.sh" -n -c "$3" -o "$work/out" > "$work/log" 2>&1; rc=$?
	if { [ "$1" = 0 ] && [ "$rc" -eq 0 ]; } || { [ "$1" != 0 ] && [ "$rc" -ne 0 ]; }; then ok "$2"; else no "$2 (rc=$rc)"; fi
}
conf good; expect 0 "valid product.conf, both profiles" "$work/good.conf"
grep -q 'release/amd64/mkisoimages.sh' "$work/log" && ok "ISO uses release/<machine>" || no "ISO uses release/<machine>"
grep -q 'out/appliance/examplebsd-appliance-amd64.iso' "$work/log" && grep -q 'out/desktop/examplebsd-desktop-amd64.iso' "$work/log" \
	&& ok "both profiles produce artifacts" || no "both profiles produce artifacts"
conf meta 'DISTRO_NAME="My Distro; touch x"' "PUBLISHER_ORG=a;touch $work/pwned2" "MOTD=it's a;b|c && touch $work/pwned3"
expect 0 "spaces and ; | & ' in values stay data" "$work/meta.conf"
[ ! -e "$work/pwned2" ] && [ ! -e "$work/pwned3" ] && ok "metacharacters are not executed" || no "metacharacters are not executed"
conf arm 'DISTRO_ARCH="aarch64"' 'FILESYSTEM_ROOT="ufs"'; expect 0 "aarch64 + ufs plan" "$work/arm.conf"
grep -q 'release/arm64/mkisoimages.sh' "$work/log" && grep -q 'makefs -t ffs' "$work/log" \
	&& ok "aarch64 uses release/arm64 and ufs uses makefs -t ffs" || no "aarch64 uses release/arm64 and ufs uses makefs -t ffs"
grep -q 'pw -R .* lock root' "$work/log" && ok "root is locked in the stage" || no "root is locked in the stage"
cp -R "$repo" "$work/repo" && printf 'if_mt76_load="YES"\n' > "$work/repo/overlay/base/rootfs/etc/bad.conf"
sh "$work/repo/build.sh" -n -c "$work/good.conf" -o "$work/out" > /dev/null 2>&1 && no "mt76 guard refuses overlay mention" || ok "mt76 guard refuses overlay mention"
conf os 'DISTRO_OS="netbsd"'; expect 1 "non-freebsd DISTRO_OS refused" "$work/os.conf"
conf slug 'DISTRO_SLUG="Bad_Slug"'; expect 1 "bad slug refused" "$work/slug.conf"
conf color 'BRAND_COLOR="#3b6ea5"'; expect 1 "BRAND_COLOR with hash refused" "$work/color.conf"
conf inj 'MOTD="x$(touch '"$work"'/pwned)"'; expect 1 "command substitution refused" "$work/inj.conf"
[ ! -e "$work/pwned" ] && ok "product.conf is not executed" || no "product.conf is not executed"
conf key 'PATH="/tmp"'; expect 1 "unknown key refused" "$work/key.conf"
conf prof 'PROFILE="server"'; expect 1 "unknown profile refused" "$work/prof.conf"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
