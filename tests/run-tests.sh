#!/bin/sh
# tests/run-tests.sh — dry-run checks for build.sh (runs on any POSIX host).
#
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
set -u
# The tree the suite reads. The knob points it at another tree: a copy of
# this one, so that a behaviour can be broken in the copy and the suite run
# against the copy without touching the working tree.
repo=${WTFBSD_REPO:-$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)}
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
grep -Eq 'touch .*firstboot' "$work/log" && ok "dry run prints the /firstboot touch" || no "dry run prints the /firstboot touch"
# -u/-k: dry run validates and prints, but writes nothing
printf 'ssh-ed25519 %sAC3NzaC1l test@example\n' AAA > "$work/ok.pub"
printf 'definitely-not-a-ssh-key\n' > "$work/bad.pub"
sh "$repo/build.sh" -n -c "$work/good.conf" -u ciuser -k "$work/ok.pub" -o "$work/u-out" > "$work/u.log" 2>&1 \
	&& ok "-u/-k: valid user/key pass validation" || no "-u/-k: valid user/key pass validation (rc=0 expected)"
grep -q 'firstboot-user.conf' "$work/u.log" && ok "-u/-k: dry run prints the plan" || no "-u/-k: dry run prints the plan"
[ ! -e "$work/u-out" ] && ok "-u/-k: dry run writes nothing" || no "-u/-k: dry run writes nothing"
sh "$repo/build.sh" -n -c "$work/good.conf" -u Ci -k "$work/ok.pub" -o "$work/u-out" > /dev/null 2>&1 \
	&& no "-u: bad username refused" || ok "-u: bad username refused"
sh "$repo/build.sh" -n -c "$work/good.conf" -u ci -k "$work/bad.pub" -o "$work/u-out" > /dev/null 2>&1 \
	&& no "-k: bad key line refused" || ok "-k: bad key line refused"
sh "$repo/build.sh" -n -c "$work/good.conf" -u ci -o "$work/u-out" > /dev/null 2>&1 \
	&& no "-u without -k refused" || ok "-u without -k refused"
sh "$repo/build.sh" -n -c "$work/good.conf" -k "$work/ok.pub" -o "$work/u-out" > /dev/null 2>&1 \
	&& no "-k without -u refused" || ok "-k without -u refused"
# rc.conf.d fragments are named after their services
_misnamed=''
for _f in $(find "$repo/overlay" -type f -path '*etc/rc.conf.d/*' | sed 's|.*/||'); do
	case $_f in
	appliance | desktop | examplebsd) _misnamed="$_misnamed $_f" ;;
	esac
done
[ -z "$_misnamed" ] && ok "no misnamed rc.conf.d fragment (appliance|desktop|examplebsd)" \
	|| no "misnamed rc.conf.d fragments:$_misnamed"
for _f in sshd dbus lightdm ntpd hostname firstboot_user; do
	[ -n "$(find "$repo/overlay" -type f -path "*etc/rc.conf.d/$_f")" ] \
		&& ok "rc.conf.d/$_f exists" || no "rc.conf.d/$_f exists"
done
cp -R "$repo" "$work/repo" && printf 'if_mt76_load="YES"\n' > "$work/repo/overlay/base/rootfs/etc/bad.conf"
sh "$work/repo/build.sh" -n -c "$work/good.conf" -o "$work/out" > /dev/null 2>&1 && no "mt76 guard refuses overlay mention" || ok "mt76 guard refuses overlay mention"
conf os 'DISTRO_OS="netbsd"'; expect 1 "non-freebsd DISTRO_OS refused" "$work/os.conf"
conf slug 'DISTRO_SLUG="Bad_Slug"'; expect 1 "bad slug refused" "$work/slug.conf"
conf color 'BRAND_COLOR="#3b6ea5"'; expect 1 "BRAND_COLOR with hash refused" "$work/color.conf"
conf inj 'MOTD="x$(touch '"$work"'/pwned)"'; expect 1 "command substitution refused" "$work/inj.conf"
[ ! -e "$work/pwned" ] && ok "product.conf is not executed" || no "product.conf is not executed"
conf key 'PATH="/tmp"'; expect 1 "unknown key refused" "$work/key.conf"
conf prof 'PROFILE="server"'; expect 1 "unknown profile refused" "$work/prof.conf"
# syntax checks: every *.sh, the rc.d script and the (renamed-from) installer
_snbad=''
for _f in $(find "$repo" -name '*.sh'); do
	sh -n "$_f" || _snbad="$_snbad $_f"
done
sh -n "$repo/overlay/base/rootfs/etc/rc.d/firstboot_user" || _snbad="$_snbad rc.d/firstboot_user"
sh -n "$repo/overlay/base/rootfs/usr/local/sbin/@SLUG@-install" || _snbad="$_snbad @SLUG@-install"
[ -z "$_snbad" ] && ok "sh -n clean on all shell scripts" || no "sh -n fails on:$_snbad"
# the installer must not use eval (or anything else interpreted)
grep -Eq '\beval\b' "$repo/overlay/base/rootfs/usr/local/sbin/@SLUG@-install" \
	&& no "installer contains no eval" || ok "installer contains no eval"

# ------------------------------------------------------------------
# (j) the three defects the first real build found. A dry run never
#     runs makefs(8) and never writes anything, so these are the
#     checks a dry run can make.
# ------------------------------------------------------------------

# (j0) the root pool name: makefs(8) -t zfs takes a letter, then only
#      letters, digits and '_' (usr.sbin/makefs/zfs.c); a '-' fails the
#      image step after the whole world is built. The slug may hold '-'.
conf poolslug 'DISTRO_SLUG="example-bsd"'
sh "$repo/build.sh" -n -c "$work/poolslug.conf" -o "$work/out" > "$work/pool.log" 2>&1
_pool=$(sed -n 's/.*-o poolname=\([^ ]*\).*/\1/p' "$work/pool.log" | head -1)
case $_pool in
[A-Za-z]*[!A-Za-z0-9_]* | '' | [!A-Za-z]*) no "the root pool name is one makefs accepts (got: '$_pool')" ;;
*) ok "the root pool name is one makefs accepts ($_pool)" ;;
esac

# (j0b) the placeholder substitution keeps the mode of a file: an overlay
#       script (usr/local/sbin/@SLUG@-install) that loses its exec bit is
#       refused by the start script of the live ISO ("Permission denied")
_sx=$(mktemp -d)
mkdir -p "$_sx/stage/usr/local/sbin"
printf '#!/bin/sh\necho @SLUG@\n' > "$_sx/stage/usr/local/sbin/x"
chmod 755 "$_sx/stage/usr/local/sbin/x"
printf 's/@SLUG@/examplebsd/g\n' > "$_sx/sub.sed"
( umask 022
  eval "$(sed -n '/^subst_overlay() {/,/^}/p' "$repo/build.sh")"
  SUBFILE="$_sx/sub.sed" subst_overlay "$_sx/stage" "$_sx/stage" ) > /dev/null 2>&1
if [ -x "$_sx/stage/usr/local/sbin/x" ] && grep -q examplebsd "$_sx/stage/usr/local/sbin/x"; then
	ok "the placeholder substitution keeps an overlay script executable"
else
	no "the placeholder substitution keeps an overlay script executable"
fi
rm -rf "$_sx"

# (j1) the size of the root filesystem: makefs(8) parses -s with a
#      lowercase suffix only, so '12G' is an illegal number to it.
sh "$repo/build.sh" -n -c "$work/good.conf" -o "$work/out" > "$work/rootsize.log" 2>&1
if grep -q -- '-s 12g' "$work/rootsize.log" && ! grep -q -- '-s 12G' "$work/rootsize.log"; then
	ok "the default root size is lowercase (makefs takes a lowercase suffix)"
else
	no "the default root size is lowercase (makefs takes a lowercase suffix)"
fi
# a size that is given in uppercase is normalised before it reaches makefs
ROOTSIZE=12G sh "$repo/build.sh" -n -c "$work/good.conf" -o "$work/out" > "$work/rootsize-up.log" 2>&1
if grep -q -- '-s 12g' "$work/rootsize-up.log" && ! grep -q -- '-s 12G' "$work/rootsize-up.log"; then
	ok "a root size in uppercase is normalised to lowercase"
else
	no "a root size in uppercase is normalised to lowercase"
fi
# a size that makefs cannot read is refused
ROOTSIZE=12x sh "$repo/build.sh" -n -c "$work/good.conf" -o "$work/out" > "$work/rootsize-bad.log" 2>&1
_rc=$?
if [ "$_rc" -ne 0 ] && grep -qi 'ROOTSIZE' "$work/rootsize-bad.log"; then
	ok "a root size that makefs cannot read is refused"
else
	no "a root size that makefs cannot read is refused (rc=$_rc)"
fi
# a size with no suffix at all is a number of bytes and is accepted
ROOTSIZE=1048576 sh "$repo/build.sh" -n -c "$work/good.conf" -o "$work/out" > "$work/rootsize-num.log" 2>&1
if grep -q -- '-s 1048576' "$work/rootsize-num.log"; then
	ok "a root size without a suffix is passed on as it is"
else
	no "a root size without a suffix is passed on as it is"
fi

# (j2) the product configuration that apply-answers.sh writes: a comment
#      header and one KEY='value' line per answer.
cat > "$work/answers.conf" <<'EOF'
# product.conf — generated by scripts/apply-answers.sh from answers.yaml
# The contract is questions.yaml; the flow is AGENTS.md / docs/E2E.md.
# POSIX sh sourceable. Regenerate instead of hand-editing.
#
DISTRO_OS='freebsd'
DISTRO_NAME='ExampleBSD'
DISTRO_SLUG='examplebsd'
DISTRO_ARCH='amd64'
FILESYSTEM_ROOT='zfs'
ZFS_DATA_POOL='no'
PROFILE='both'
PACKAGE_SET='minimal'
INSTALLER='tui'
MOTD='built from the wtfbsd templates'
BRAND_COLOR='3b6ea5'
BRAND_URL='https://example.org'
#
# honest per-OS row used for this build (from questions.yaml):
#   DISTRO_OS  freebsd
#   arch       amd64
#   root_fs    zfs
#   installer  tui
#   zfs_pool   no
EOF
sh "$repo/build.sh" -n -c "$work/answers.conf" -o "$work/out" > "$work/answers.log" 2>&1
_rc=$?
if [ "$_rc" -eq 0 ]; then
	ok "the product.conf of apply-answers.sh (single-quoted) is accepted"
else
	no "the product.conf of apply-answers.sh (single-quoted) is accepted (rc=$_rc)"
fi
# a value with a mix of the two quotes is refused
printf '%s\n' "DISTRO_OS='freebsd'" "DISTRO_NAME='ExampleBSD'" "DISTRO_SLUG='examplebsd'" 'MOTD="it'"'" > "$work/mixed.conf"
sh "$repo/build.sh" -n -c "$work/mixed.conf" -o "$work/out" > "$work/mixed.log" 2>&1
_rc=$?
if [ "$_rc" -ne 0 ] && grep -qi 'quote' "$work/mixed.log"; then
	ok "a value with a mix of single and double quotes is refused"
else
	no "a value with a mix of single and double quotes is refused (rc=$_rc)"
fi
# a value with a quote inside its quotes is refused
printf '%s\n' "DISTRO_OS='freebsd'" "DISTRO_NAME='ExampleBSD'" "DISTRO_SLUG='examplebsd'" "MOTD=\"it's\"" > "$work/inner.conf"
sh "$repo/build.sh" -n -c "$work/inner.conf" -o "$work/out" > "$work/inner.log" 2>&1
_rc=$?
if [ "$_rc" -ne 0 ] && grep -qi 'quote' "$work/inner.log"; then
	ok "a value with a quote inside its quotes is refused"
else
	no "a value with a quote inside its quotes is refused (rc=$_rc)"
fi
# a bare value with an apostrophe is still data and is still accepted
printf '%s\n' "DISTRO_OS='freebsd'" "DISTRO_NAME='ExampleBSD'" "DISTRO_SLUG='examplebsd'" "MOTD=it's fine" > "$work/bare-quote.conf"
sh "$repo/build.sh" -n -c "$work/bare-quote.conf" -o "$work/out" > "$work/bare-quote.log" 2>&1
_rc=$?
if [ "$_rc" -eq 0 ]; then
	ok "a bare value with an apostrophe is accepted"
else
	no "a bare value with an apostrophe is accepted (rc=$_rc)"
fi

# (j3) the output directory is absolute: the build runs make(1) inside
#      the source tree, where a relative DESTDIR would land in the
#      source tree instead of in the output directory.
( cd "$work" && sh "$repo/build.sh" -n -c "$work/good.conf" -o relative-out ) > "$work/abs.log" 2>&1
_outline=$(sed -n 's/^  out  *//p' "$work/abs.log" 2>/dev/null | head -1 | sed 's/[[:space:]].*$//')
if [ "$_outline" = "$work/relative-out" ] && [ ! -e "$work/relative-out" ]; then
	ok "the output directory of the plan is absolute"
else
	no "the output directory of the plan is absolute (got '$_outline')"
fi
# the artifacts of the plan are absolute as well
if grep -q -- "$work/relative-out/appliance/examplebsd-appliance-amd64.img" "$work/abs.log"; then
	ok "the artifacts of the plan are absolute"
else
	no "the artifacts of the plan are absolute"
fi

# ------------------------------------------------------------------
# CI: the pluggable VM layer, the boot test, the shipped agents
# ------------------------------------------------------------------
VMSH="$repo/ci/vm.sh"
BOOTSH="$repo/tests/boot-test.sh"
FAKE="$repo/tests/fixtures/fake-provider.sh"
FIXTURES="$repo/tests/fixtures"

# ------------------------------------------------------------------
# The Jenkinsfile, parsed.
#
# A test must not pass because a word sits in a comment, so the comments
# are stripped before anything is matched, and the blocks of the file are
# parsed (by their braces) instead of being grepped for a phrase.
# ------------------------------------------------------------------

# jn_code — the Jenkinsfile without its comments
jn_code() {
	awk '{ sub(/\/\/.*/, "") ; print }' "$repo/Jenkinsfile"
}

# jn_block — the block of the Jenkinsfile that starts at a header, with
# the braces counted. The header is a plain text, not a pattern.
jn_block() { # jn_block <header-text>
	jn_code | awk -v hdr="$1" '
		!inside && index($0, hdr) { inside = 1 }
		inside {
			rest = $0
			o = gsub(/\{/, "{", rest)
			c = gsub(/\}/, "}", rest)
			depth += o - c
			print $0
			if (depth <= 0) exit
		}'
}

# jn_sh — the shell blocks of the Jenkinsfile: the text between the
# triple-quoted strings
jn_sh() {
	jn_code | awk "/'''/{ if (inb) { inb = 0 } else { inb = 1 }; next } inb { print }"
}

# jn_sh_code — the shell blocks without their comments
jn_sh_code() {
	jn_sh | sed -e 's/[[:space:]]#.*$//' -e 's/^#.*$//'
}

# jn_sh_files — write every shell block of the pipeline into its own file
jn_sh_files() { # jn_sh_files <dir>
	mkdir -p "$1"
	awk -v dir="$1" "/'''/{ n++; file = sprintf(\"%s/block-%03d.sh\", dir, n); inb = !inb; next } inb { print > file }" \
		"$repo/Jenkinsfile"
}

# marked — the text between two markers of a file
marked() { # marked <file> <begin> <end>
	sed -n "/$2/,/$3/p" "$1" | sed -e '1d' -e '$d'
}

# The patterns used below are assembled from fragments so that this file does
# not itself contain the strings it looks for.
_frag() { printf '%s' "$1$2"; }
_nokeys="\"($(_frag 'pro' 'vider')|$(_frag 'mo' 'del')|$(_frag 'base' 'URL')|$(_frag 'api' 'Key')|$(_frag 'm' 'cp'))\""

# (a) an unknown or missing provider fails closed: nothing is started
_msg=$(WTFBSD_VM_PROVIDER=nosuchprovider sh "$VMSH" create vmtest /dev/null 2>&1); _rc=$?
if [ "$_rc" -ne 0 ] && printf '%s' "$_msg" | grep -q 'unknown VM provider'; then
	ok "ci/vm.sh: unknown provider fails closed"
else
	no "ci/vm.sh: unknown provider fails closed (rc=$_rc)"
fi
_msg=$(unset WTFBSD_VM_PROVIDER; sh "$VMSH" create vmtest /dev/null 2>&1); _rc=$?
if [ "$_rc" -ne 0 ] && printf '%s' "$_msg" | grep -q 'no VM provider'; then
	ok "ci/vm.sh: missing provider fails closed"
else
	no "ci/vm.sh: missing provider fails closed (rc=$_rc)"
fi

# (b) a VM name outside ^[a-z][a-z0-9-]{0,30}$ is refused
_msg=$(WTFBSD_VM_PROVIDER=bhyve sh "$VMSH" create 'Bad Name' /dev/null 2>&1); _rc=$?
if [ "$_rc" -ne 0 ] && printf '%s' "$_msg" | grep -q 'must match'; then
	ok "ci/vm.sh: bad VM name refused"
else
	no "ci/vm.sh: bad VM name refused (rc=$_rc)"
fi
_msg=$(WTFBSD_VM_PROVIDER=bhyve sh "$VMSH" create aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa /dev/null 2>&1); _rc=$?
if [ "$_rc" -ne 0 ] && printf '%s' "$_msg" | grep -q 'must match'; then
	ok "ci/vm.sh: over-long VM name refused"
else
	no "ci/vm.sh: over-long VM name refused (rc=$_rc)"
fi

# (b2) the name is checked by ci/vm.sh itself, before any provider runs: the
#      fake provider records every call it gets, so a call in the log would
#      mean the provider was reached with a name it should never see.
_calls8="$work/calls-badname.log"
_msg=$(WTFBSD_VM_PROVIDER_PATH="$FAKE" WTFBSD_FAKE_CALL_LOG="$_calls8" \
	sh "$VMSH" create 'Bad Name' /dev/null 2>&1); _rc=$?
if [ "$_rc" -ne 0 ] && [ ! -s "$_calls8" ] && printf '%s' "$_msg" | grep -q '^vm.sh:'; then
	ok "ci/vm.sh: a bad VM name is refused before the provider runs"
else
	no "ci/vm.sh: a bad VM name is refused before the provider runs (rc=$_rc)"
fi

# (b3) a name with a newline in it is refused: a line-based match accepts
#      the first line of such a name, so the rules are checked with case
#      patterns and a length check.
_badname=$(printf 'ok\nx')
_msg=$(WTFBSD_VM_PROVIDER=bhyve sh "$VMSH" create "$_badname" /dev/null 2>&1); _rc=$?
if [ "$_rc" -ne 0 ] && printf '%s' "$_msg" | grep -q 'must match'; then
	ok "ci/vm.sh: a VM name with a newline in it is refused"
else
	no "ci/vm.sh: a VM name with a newline in it is refused (rc=$_rc)"
fi
_msg=$(sh "$repo/ci/providers/bhyve.sh" create "$_badname" /dev/null 2>&1); _rc=$?
if [ "$_rc" -ne 0 ] && printf '%s' "$_msg" | grep -q 'must match'; then
	ok "bhyve provider: a VM name with a newline in it is refused"
else
	no "bhyve provider: a VM name with a newline in it is refused (rc=$_rc)"
fi
_msg=$(WTFBSD_FAKE_CONSOLE_LOG="$FIXTURES/serial-login.log" \
	WTFBSD_FAKE_CONSOLE_DIR="$work/console-newline" \
	sh "$FAKE" create "$_badname" /dev/null 2>&1); _rc=$?
if [ "$_rc" -ne 0 ] && printf '%s' "$_msg" | grep -q 'must match'; then
	ok "fake provider: a VM name with a newline in it is refused"
else
	no "fake provider: a VM name with a newline in it is refused (rc=$_rc)"
fi

# (c) the bhyve provider refuses a tap name outside ^[a-z][a-z0-9]*[0-9]+$
_msg=$(WTFBSD_VM_PROVIDER=bhyve WTFBSD_TAP='tap0;rm' sh "$VMSH" create vmtest /dev/null 2>&1); _rc=$?
if [ "$_rc" -ne 0 ] && printf '%s' "$_msg" | grep -qi 'tap'; then
	ok "bhyve provider: tap name outside the pattern refused"
else
	no "bhyve provider: tap name outside the pattern refused (rc=$_rc)"
fi
_msg=$(WTFBSD_VM_PROVIDER=bhyve WTFBSD_BRIDGE='bridge0;rm' sh "$VMSH" create vmtest /dev/null 2>&1); _rc=$?
if [ "$_rc" -ne 0 ] && printf '%s' "$_msg" | grep -qi 'bridge'; then
	ok "bhyve provider: bridge name outside the pattern refused"
else
	no "bhyve provider: bridge name outside the pattern refused (rc=$_rc)"
fi

# (c2) the serial console reader: an nmdm end opens in canonical mode with
#      ECHO and getty's "login: " prompt has no newline, so the reader must
#      put the device into raw mode without echo, on the same open file it
#      reads from.
if grep -E 'stty raw -echo.*<[[:space:]]*"/dev/nmdm' "$repo/ci/providers/bhyve.sh" >/dev/null 2>&1; then
	ok "bhyve provider: the nmdm reader sets raw mode on the same open"
else
	no "bhyve provider: the nmdm reader sets raw mode on the same open"
fi
if grep -E 'cat[[:space:]]+"/dev/nmdm' "$repo/ci/providers/bhyve.sh" >/dev/null 2>&1; then
	no "bhyve provider: the nmdm reader is not a plain cat"
else
	ok "bhyve provider: the nmdm reader is not a plain cat"
fi

# (c3) the VM name the boot test uses: the caller may name it, so that the
#      pipeline can destroy it even when the boot test dies hard.
_name="boot-appliance-chosen"
_calls4="$work/calls-named.log"
_msg=$(WTFBSD_VM_PROVIDER_PATH="$FAKE" WTFBSD_FAKE_CALL_LOG="$_calls4" \
	WTFBSD_FAKE_CONSOLE_LOG="$FIXTURES/serial-login.log" \
	WTFBSD_FAKE_CONSOLE_DIR="$work/console-named" \
	sh "$BOOTSH" "$FIXTURES/fake-image.img" desktop "$_name" 2>&1); _rc=$?
_created3=$(sed -n 's/^create \([^ ]*\) .*/\1/p' "$_calls4" 2>/dev/null | head -1)
if [ "$_rc" -eq 0 ] && [ "$_created3" = "$_name" ]; then
	ok "boot test: uses the VM name it is given"
else
	no "boot test: uses the VM name it is given (rc=$_rc created=$_created3)"
fi
_name2="boot-desktop-fromenv"
_calls5="$work/calls-env.log"
_msg=$(WTFBSD_VM_NAME="$_name2" WTFBSD_VM_PROVIDER_PATH="$FAKE" WTFBSD_FAKE_CALL_LOG="$_calls5" \
	WTFBSD_FAKE_CONSOLE_LOG="$FIXTURES/serial-login.log" \
	WTFBSD_FAKE_CONSOLE_DIR="$work/console-env" \
	sh "$BOOTSH" "$FIXTURES/fake-image.img" desktop 2>&1); _rc=$?
_created4=$(sed -n 's/^create \([^ ]*\) .*/\1/p' "$_calls5" 2>/dev/null | head -1)
if [ "$_rc" -eq 0 ] && [ "$_created4" = "$_name2" ]; then
	ok "boot test: uses WTFBSD_VM_NAME when no name is given"
else
	no "boot test: uses WTFBSD_VM_NAME when no name is given (rc=$_rc created=$_created4)"
fi

# (c4) the pipeline's VM name helper: the Jenkinsfile computes the names, so
#      the helper lives in the Jenkinsfile and is extracted from it here.
_vmfn=$(sed -n '/vm-name-begin/,/vm-name-end/p' "$repo/Jenkinsfile" 2>/dev/null | sed -e '1d' -e '$d')
printf '%s\n' "$_vmfn" 'vm_name "$1"' > "$work/vmname.sh"
_out=$(sh "$work/vmname.sh" 'boot-Desktop-My_Job-42' 2>/dev/null || printf '')
if printf '%s' "$_out" | grep -Eq '^boot-desktop-my-job-42-[0-9a-f]{6}$'; then
	ok "Jenkinsfile: the VM name helper lowercases and sanitises"
else
	no "Jenkinsfile: the VM name helper lowercases and sanitises (got '$_out')"
fi
_out2=$(sh "$work/vmname.sh" 'boot-appliance-a-very-long-jenkins-job-name-1234' 2>/dev/null || printf '')
if printf '%s' "$_out2" | grep -Eq '^[a-z][a-z0-9-]{0,30}$' &&
	printf '%s' "$_out2" | grep -Eq '[0-9a-f]{6}$'; then
	ok "Jenkinsfile: the VM name helper keeps the name inside the name rules"
else
	no "Jenkinsfile: the VM name helper keeps the name inside the name rules (got '$_out2')"
fi

# (c5) the pipeline names its VMs after the job, lists them before it creates
#      them, truncates the list at the start of the build, and destroys every
#      listed name when the build ends.
_jn_line() { jn_code | grep -nF -- "$1" 2>/dev/null | head -1 | cut -d: -f1; }
_jn_before() { # _jn_before <first> <second>
	_a=$(_jn_line "$1")
	_b=$(_jn_line "$2")
	[ -n "$_a" ] && [ -n "$_b" ] && [ "$_a" -lt "$_b" ]
}
if jn_code | grep -q 'vm_build_name boot-' && jn_code | grep -q 'vm_build_name build'; then
	ok "Jenkinsfile: the boot and build VMs are named after the job"
else
	no "Jenkinsfile: the boot and build VMs are named after the job"
fi
if _jn_before 'printf '"'"'%s\n'"'"' "$boot_name" >> "$list"' 'tests/boot-test.sh'; then
	ok "Jenkinsfile: the boot VM is listed before it is created"
else
	no "Jenkinsfile: the boot VM is listed before it is created"
fi
if _jn_before 'printf '"'"'%s\n'"'"' "$build_name" >> "$list"' 'ci/vm.sh create "$build_name"'; then
	ok "Jenkinsfile: the build VM is listed before it is created"
else
	no "Jenkinsfile: the build VM is listed before it is created"
fi
if grep -q 'ci/vm.sh destroy "$name"' "$repo/Jenkinsfile"; then
	ok "Jenkinsfile: post { always } destroys every listed VM"
else
	no "Jenkinsfile: post { always } destroys every listed VM"
fi

# (c6) the build inside a VM: the product.conf must land next to the source
#      tree the build runs in, and every ssh and scp must be unattended and
#      must not trust an unknown host key silently.
if grep -F '"$raddr:$build_dir/product.conf"' "$repo/Jenkinsfile" >/dev/null 2>&1; then
	ok "Jenkinsfile: product.conf is copied into the build directory"
else
	no "Jenkinsfile: product.conf is copied into the build directory"
fi
_sshbad=''
while IFS= read -r _l; do
	case $_l in
	*BatchMode=yes*StrictHostKeyChecking=accept-new*UserKnownHostsFile=*) : ;;
	*) _sshbad="$_sshbad $_l" ;;
	esac
done <<EOF
$(grep -E '^[[:space:]]*(ssh|scp)[[:space:]]' "$repo/Jenkinsfile")
EOF
if [ -z "$_sshbad" ]; then
	ok "Jenkinsfile: every ssh and scp is unattended and pins the known hosts file"
else
	no "Jenkinsfile: every ssh and scp is unattended and pins the known hosts file:$_sshbad"
fi

# (c20) the paths that cross into the build VM are checked before they are
#       used: they end up in the command that the shell of the remote host
#       reads, and a path that carries a quote or a space ends the quoting
#       it is put in. The helper is taken out of the pipeline and run here,
#       so that the test cannot drift from the text that runs.
_remote_path=$(marked "$repo/Jenkinsfile" '# remote-path-begin' '# remote-path-end')
if [ -n "$_remote_path" ]; then
	printf '%s\n' "$_remote_path" 'check_remote_path "$1" TESTPATH' > "$work/remote-path.sh"
	_rp_bad=''
	for _rp in /usr/local/src/freebsd-template /usr/src /opt/a_b.c-d /usr/src.1; do
		sh "$work/remote-path.sh" "$_rp" >/dev/null 2>&1 || _rp_bad="$_rp_bad $_rp"
	done
	if [ -z "$_rp_bad" ]; then
		ok "Jenkinsfile: an absolute path of boring characters is accepted"
	else
		no "Jenkinsfile: an absolute path of boring characters is accepted:$_rp_bad"
	fi
	_rp_bad=''
	for _rp in "" "relative/path" "/usr/src with space" "/usr/src;id" "/usr/src'rm -rf /" \
		'/usr/src$(id)' '/usr/src`id`' '/usr/src$HOME' '/usr/src&' '/usr/src|' '/usr/src>' ; do
		sh "$work/remote-path.sh" "$_rp" >/dev/null 2>&1 && _rp_bad="$_rp_bad [$_rp]"
	done
	if [ -z "$_rp_bad" ]; then
		ok "Jenkinsfile: a path that is not an absolute path of boring characters is refused"
	else
		no "Jenkinsfile: a path that is not an absolute path of boring characters is refused:$_rp_bad"
	fi
else
	no "Jenkinsfile: the remote path helper is in the pipeline"
fi
# and the Build stage calls it for both paths, before it uses them
_build=$(jn_block "stage('Build')")
if printf '%s\n' "$_build" | grep -q 'check_remote_path' &&
	printf '%s\n' "$_build" | grep -q 'WTFBSD_VM_BUILD_DIR' &&
	printf '%s\n' "$_build" | grep -q 'WTFBSD_VM_SRC'; then
	ok "Jenkinsfile: the Build stage checks the paths it sends to the build VM"
else
	no "Jenkinsfile: the Build stage checks the paths it sends to the build VM"
fi

# (c21) the agent label: the parameter is empty on the first run of a fresh
#       job, and the label is checked by Jenkins when it allocates the
#       agent, which happens before any stage runs. The agent directive
#       therefore falls back to the default label. The directive is Groovy,
#       so this is a check on its shape and not on a run of it.
_agent=$(jn_block 'agent {')
if printf '%s\n' "$_agent" | grep -Fq 'AGENT_LABEL' &&
	printf '%s\n' "$_agent" | grep -Fq '?:' &&
	printf '%s\n' "$_agent" | grep -Fq 'bsd-builder'; then
	ok "Jenkinsfile: the agent directive falls back to the default label"
else
	no "Jenkinsfile: the agent directive falls back to the default label"
fi

# (c22) the provider contract: stdout carries the machine-readable answer
#       and nothing else, because the boot test captures the path of the
#       console log and the address of the VM from it. The progress of a
#       provider goes to stderr.
mkdir -p "$work/console-only"
: > "$work/console-only/vmtest.log"
_out=$(WTFBSD_CONSOLE_DIR="$work/console-only" "$repo/ci/providers/bhyve.sh" console vmtest 2>/dev/null)
if [ "$_out" = "$work/console-only/vmtest.log" ]; then
	ok "the reference provider prints only the path of the console log on stdout"
else
	no "the reference provider prints only the path of the console log on stdout (got:$_out)"
fi
_out=$(WTFBSD_VM_PROVIDER_PATH="$FAKE" WTFBSD_FAKE_CALL_LOG="$work/calls-stdout.log" \
	WTFBSD_FAKE_CONSOLE_LOG="$FIXTURES/serial-login.log" \
	WTFBSD_FAKE_CONSOLE_DIR="$work/console-stdout" \
	sh "$FAKE" create vmtest "$FIXTURES/fake-image.img" 2>/dev/null)
_err=$(WTFBSD_VM_PROVIDER_PATH="$FAKE" WTFBSD_FAKE_CALL_LOG="$work/calls-stderr.log" \
	WTFBSD_FAKE_CONSOLE_LOG="$FIXTURES/serial-login.log" \
	WTFBSD_FAKE_CONSOLE_DIR="$work/console-stderr" \
	sh "$FAKE" create vmtest "$FIXTURES/fake-image.img" 2>&1 >/dev/null)
if [ -z "$_out" ] && [ -n "$_err" ]; then
	ok "a provider writes its progress to stderr, not to stdout"
else
	no "a provider writes its progress to stderr, not to stdout (stdout:$_out)"
fi

# (c23) the Boot test stage: the image is looked up with a command that
#       does not fail when there is no image, so that the message of the
#       pipeline reaches the operator instead of a raw exit status.
_imgcmd=$(sed -n 's|.*def img = sh(script: "\(.*\)", returnStdout: true).*|\1|p' "$repo/Jenkinsfile" | head -1)
_imgcmd=$(printf '%s' "$_imgcmd" | sed 's|${p}|appliance|g')
_imglist="$work/imglist"
mkdir -p "$_imglist/out/appliance"
_out=$(cd "$_imglist" && sh -c "$_imgcmd" 2>/dev/null); _rc=$?
if [ "$_rc" -eq 0 ] && [ -z "$_out" ]; then
	ok "Jenkinsfile: the lookup of the image does not fail when there is no image"
else
	no "Jenkinsfile: the lookup of the image does not fail when there is no image (rc=$_rc out:$_out)"
fi
: > "$_imglist/out/appliance/examplebsd-appliance-amd64.img"
_out=$(cd "$_imglist" && sh -c "$_imgcmd" 2>/dev/null); _rc=$?
if [ "$_rc" -eq 0 ] && [ -n "$_out" ]; then
	ok "Jenkinsfile: the lookup of the image finds the image that was built"
else
	no "Jenkinsfile: the lookup of the image finds the image that was built (rc=$_rc out:$_out)"
fi

# (c24) the post { always } of the pipeline: a destroy that failed is a VM
#       that may still be running. Every name in the list is destroyed, and
#       the build is failed with the names that could not be destroyed.
_post=$(jn_block 'post {')
_postsh=$(printf '%s\n' "$_post" | awk "/'''/{ if (inb) { inb = 0 } else { inb = 1 }; next } inb { print }")
_pldir="$work/posttest"
mkdir -p "$_pldir/ci"
cat > "$_pldir/ci/vm.sh" <<'EOF'
#!/bin/sh
# a stub that records the destroys it gets, and that fails for one name
printf '%s\n' "$1 $2" >> "$WTFBSD_POST_LOG"
case $2 in
leaked-vm) printf 'the VM is still there\n' >&2; exit 3 ;;
esac
exit 0
EOF
chmod +x "$_pldir/ci/vm.sh"
# the failing name comes first: the names behind it have to be destroyed
# as well
printf 'leaked-vm\ngood-vm\n' > "$_pldir/.wtfbsd-vms"
: > "$work/post.log"
_out=$(cd "$_pldir" && WORKSPACE="$_pldir" WTFBSD_POST_LOG="$work/post.log" sh -c "$_postsh" 2>/dev/null); _rc=$?
if [ "$_rc" -eq 0 ] && printf '%s' "$_out" | grep -q 'leaked-vm' &&
	! printf '%s' "$_out" | grep -q 'good-vm' &&
	grep -q 'destroy leaked-vm' "$work/post.log" 2>/dev/null &&
	grep -q 'destroy good-vm' "$work/post.log" 2>/dev/null; then
	ok "Jenkinsfile: the post { always } names the VMs that could not be destroyed"
else
	no "Jenkinsfile: the post { always } names the VMs that could not be destroyed (rc=$_rc out:$_out)"
fi
_l_sh=$(printf '%s\n' "$_post" | grep -n 'def leaked = sh(' | head -1 | cut -d: -f1)
_l_res=$(printf '%s\n' "$_post" | grep -n "currentBuild.result = 'FAILURE'" | head -1 | cut -d: -f1)
if [ -n "$_l_sh" ] && [ -n "$_l_res" ] && [ "$_l_sh" -lt "$_l_res" ]; then
	ok "Jenkinsfile: the post { always } fails the build when a destroy failed"
else
	no "Jenkinsfile: the post { always } fails the build when a destroy failed"
fi

# (c7) destroying a VM: a missing bhyvectl(8) is a failure, and a VM that
#      is already gone is not a failure. bhyvectl(8) lives in /usr/sbin, so
#      a PATH without it is a host without it.
_msg=$(PATH=/usr/bin:/bin WTFBSD_CONSOLE_DIR="$work/console-destroy" \
	"$repo/ci/providers/bhyve.sh" destroy testvm 2>&1); _rc=$?
if [ "$_rc" -ne 0 ] && ! printf '%s' "$_msg" | grep -q 'destroyed'; then
	ok "bhyve provider: destroy fails when bhyvectl is missing"
else
	no "bhyve provider: destroy fails when bhyvectl is missing (rc=$_rc)"
fi
mkdir -p "$work/fakebin" "$work/devices"
printf '#!/bin/sh\necho "vm_open: testvm could not be opened: No such file or directory" >&2\nexit 1\n' \
	> "$work/fakebin/bhyvectl"
chmod +x "$work/fakebin/bhyvectl"
# the provider wants to be root to talk to the hypervisor; a stub lets the
# destroy path be exercised on a host that is not root
printf '#!/bin/sh\necho 0\n' > "$work/fakebin/id"
chmod +x "$work/fakebin/id"
: > "$work/devices/testvm"
_msg=$(PATH="$work/fakebin:$PATH" WTFBSD_VM_DEVICE_DIR="$work/devices" \
	WTFBSD_CONSOLE_DIR="$work/console-destroy2" \
	sh "$repo/ci/providers/bhyve.sh" destroy testvm 2>&1); _rc=$?
if [ "$_rc" -eq 0 ] && printf '%s' "$_msg" | grep -q 'not running' \
	&& ! printf '%s' "$_msg" | grep -q 'destroyed'; then
	ok "bhyve provider: a VM that is already gone is not a failure"
else
	no "bhyve provider: a VM that is already gone is not a failure (rc=$_rc)"
fi

# (c8) two jobs on one host must not fight over the same null-modem pair or
#      the same tap: the executor number the agent reports gives each job
#      its own. A console reader left over from an earlier run holds the
#      null-modem end open and must be stopped before a new one starts.
# the provider is run as a user that is not root (a fake id(1)), so that
# a suite run as root on a build agent never creates a tap or starts bhyve
mkdir -p "$work/c8bin"
printf '#!/bin/sh\necho 1000\n' > "$work/c8bin/id"
chmod +x "$work/c8bin/id"
_msg=$(PATH="$work/c8bin:$PATH" EXECUTOR_NUMBER=3 WTFBSD_CONSOLE_DIR="$work/console-exec" \
	"$repo/ci/providers/bhyve.sh" create vmtest "$FIXTURES/fake-image.img" 2>&1); _rc=$?
if printf '%s' "$_msg" | grep -q 'tap tap3' && printf '%s' "$_msg" | grep -q 'nmdm3B'; then
	ok "bhyve provider: the executor number picks the tap and the null-modem pair"
else
	no "bhyve provider: the executor number picks the tap and the null-modem pair"
fi
_msg=$(PATH="$work/c8bin:$PATH" EXECUTOR_NUMBER=3 WTFBSD_TAP=tap7 WTFBSD_CONSOLE_DIR="$work/console-exec2" \
	"$repo/ci/providers/bhyve.sh" create vmtest "$FIXTURES/fake-image.img" 2>&1); _rc=$?
if printf '%s' "$_msg" | grep -q 'tap tap7'; then
	ok "bhyve provider: an explicit tap wins over the executor number"
else
	no "bhyve provider: an explicit tap wins over the executor number"
fi
mkdir -p "$work/console-stale"
sleep 5 &
_stale=$!
printf '%s\n' "$_stale" > "$work/console-stale/vmtest.reader.pid"
PATH="$work/c8bin:$PATH" WTFBSD_CONSOLE_DIR="$work/console-stale" "$repo/ci/providers/bhyve.sh" \
	create vmtest "$FIXTURES/fake-image.img" >/dev/null 2>&1
_st=0
wait "$_stale" 2>/dev/null || _st=$?
if [ "$_st" -ne 0 ]; then
	ok "bhyve provider: a reader left over from an earlier run is stopped"
else
	kill "$_stale" 2>/dev/null || true
	no "bhyve provider: a reader left over from an earlier run is stopped"
fi

# (c9) the README does not tell an operator to use a keyword that
#      ifconfig(8) does not have. What the provider does with the tap is
#      asserted with a fake ifconfig further down (see (c16) and (c17)).
if grep -F 'master bridge' "$repo/README.md" >/dev/null 2>&1; then
	no "README: the host setup uses no keyword that ifconfig(8) does not have"
else
	ok "README: the host setup uses no keyword that ifconfig(8) does not have"
fi
if grep -F 'edk2-bhyve' "$repo/README.md" >/dev/null 2>&1; then
	ok "README: the firmware package is named"
else
	no "README: the firmware package is named"
fi
if grep -F 'vm-bhyve' "$repo/README.md" >/dev/null 2>&1; then
	no "README: the host setup asks for no package that bhyve(8) does not need"
else
	ok "README: the host setup asks for no package that bhyve(8) does not need"
fi

# (c10) a file parameter does not land in the workspace of a Pipeline
#       (JENKINS-27413): the File Parameter plugin stashes the file under
#       the name of the parameter, and unstash() takes it back into the
#       workspace. The parameters block is parsed, not grepped: stashedFile
#       is a parameter type, not a step.
_params=$(jn_block 'parameters {')
if printf '%s\n' "$_params" | grep -Eq 'stashedFile[[:space:]]*\(' &&
	printf '%s\n' "$_params" | grep -Eq "name:[[:space:]]*'PRODUCT_CONF'"; then
	ok "Jenkinsfile: the parameters block declares the stashed file parameter"
else
	no "Jenkinsfile: the parameters block declares the stashed file parameter"
fi
if printf '%s\n' "$_params" | grep -Eq '(^|[^A-Za-z0-9_])file[[:space:]]*\('; then
	no "Jenkinsfile: the parameters block declares no plain file parameter"
else
	ok "Jenkinsfile: the parameters block declares no plain file parameter"
fi
_nstashed=$(jn_code | grep -c 'stashedFile' || true)
if [ "${_nstashed:-0}" -eq 1 ]; then
	ok "Jenkinsfile: stashedFile is a parameter type, not a step"
else
	no "Jenkinsfile: stashedFile is a parameter type, not a step (found ${_nstashed:-0})"
fi
if jn_code | grep -q "unstash 'PRODUCT_CONF'"; then
	ok "Jenkinsfile: the pipeline takes the stashed file back with unstash"
else
	no "Jenkinsfile: the pipeline takes the stashed file back with unstash"
fi
if jn_sh | grep -q 'unstash'; then
	no "Jenkinsfile: unstash is a step of the pipeline, not a shell command"
else
	ok "Jenkinsfile: unstash is a step of the pipeline, not a shell command"
fi
# the shell step that takes the file: it copies the parameter into
# product.conf
_pc=$(marked "$repo/Jenkinsfile" '# product-conf-begin' '# product-conf-end')
printf 'DISTRO_OS="freebsd"\n' > "$work/PRODUCT_CONF"
if [ -n "$_pc" ] && ( cd "$work" && printf '%s\n' "$_pc" | sh ) > "$work/pc.log" 2>&1 &&
	[ -f "$work/product.conf" ] && cmp -s "$work/PRODUCT_CONF" "$work/product.conf"; then
	ok "Jenkinsfile: the stashed file becomes product.conf"
else
	no "Jenkinsfile: the stashed file becomes product.conf"
fi
if grep -Fi 'file parameter plugin' "$repo/README.md" >/dev/null 2>&1; then
	ok "README: the file parameter plugin is documented"
else
	no "README: the file parameter plugin is documented"
fi
# (c10a) the branch that takes the uploaded file: the File Parameter plugin
#        sets NAME_FILENAME to the name of the file that was uploaded, and
#        leaves it empty when the optional parameter was not filled in.
#        That is what says whether there is a file to build with. The
#        block of the stage is parsed, so that the check cannot pass
#        because the word sits in a comment.
_prepare=$(jn_block "stage('Prepare')")
if printf '%s\n' "$_prepare" | grep -q 'PRODUCT_CONF_FILENAME'; then
	ok "Jenkinsfile: the upload branch tests the file name of the parameter"
else
	no "Jenkinsfile: the upload branch tests the file name of the parameter"
fi
# the plugin is not here to be tested against: the behaviour is marked as
# unverified until a real upload run has confirmed it
if grep -F 'unverified: confirm with one real upload run' "$repo/Jenkinsfile" >/dev/null 2>&1; then
	ok "Jenkinsfile: the unverified upload behaviour is marked as such"
else
	no "Jenkinsfile: the unverified upload behaviour is marked as such"
fi

# (c11) the provider runs with the privileges of the agent: bhyve(8) and
#       nmdm(4) need root, and a provider outside this repository is trusted
#       code.
if grep -F 'id -u' "$repo/ci/providers/bhyve.sh" >/dev/null 2>&1; then
	ok "bhyve provider: it checks that it runs as root"
else
	no "bhyve provider: it checks that it runs as root"
fi
if [ "$(id -u)" -ne 0 ]; then
	_msg=$(WTFBSD_CONSOLE_DIR="$work/console-root" \
		"$repo/ci/providers/bhyve.sh" create vmtest "$FIXTURES/fake-image.img" 2>&1); _rc=$?
	if [ "$_rc" -ne 0 ] && printf '%s' "$_msg" | grep -qi 'root'; then
		ok "bhyve provider: a create that is not root fails with a clear message"
	else
		no "bhyve provider: a create that is not root fails with a clear message (rc=$_rc)"
	fi
else
	ok "bhyve provider: a create that is not root fails with a clear message (not run: the suite runs as root)"
fi
if grep -Fi 'owned by root' "$repo/README.md" >/dev/null 2>&1 &&
	grep -Fi 'not be writable' "$repo/README.md" >/dev/null 2>&1; then
	ok "README: the trust of an outside provider is documented"
else
	no "README: the trust of an outside provider is documented"
fi

# (c12) the image path is an argument of bhyve(8), which splits its device
#       options on commas: a path with a comma in it is refused.
_img="$work/a,b.img"
: > "$_img"
_msg=$(WTFBSD_CONSOLE_DIR="$work/console-comma" \
	"$repo/ci/providers/bhyve.sh" create vmtest "$_img" 2>&1); _rc=$?
if [ "$_rc" -ne 0 ] && printf '%s' "$_msg" | grep -qi 'comma'; then
	ok "bhyve provider: an image path with a comma in it is refused"
else
	no "bhyve provider: an image path with a comma in it is refused (rc=$_rc)"
fi

# (c13) the Prepare stage: the list of the VMs of this build starts empty
#       and the host keys of an earlier build are stale, because the VMs
#       of this build are new. The block is taken out of the pipeline and
#       run, so that the test cannot drift from the text that runs.
_prep=$(marked "$repo/Jenkinsfile" '# prepare-begin' '# prepare-end')
mkdir -p "$work/prep"
printf 'an old VM name\n' > "$work/prep/.wtfbsd-vms"
printf 'an old host key\n' > "$work/prep/.wtfbsd-known-hosts"
if [ -n "$_prep" ] && WORKSPACE="$work/prep" sh -c "$_prep" > "$work/prep.log" 2>&1 &&
	[ ! -s "$work/prep/.wtfbsd-vms" ] && [ ! -s "$work/prep/.wtfbsd-known-hosts" ]; then
	ok "Jenkinsfile: Prepare clears the VM list and the known hosts file"
else
	no "Jenkinsfile: Prepare clears the VM list and the known hosts file"
fi

# (c14) the name of a VM: the job name with its folder and the build
#       number. Two jobs of two folders must never share a VM name, and a
#       name that is too long keeps the checksum of the raw name.
printf '%s\n' "$_vmfn" 'vm_name "$(vm_build_name boot-appliance)"' > "$work/vmname-build.sh"
_a=$(JOB_NAME='folderA/main' BUILD_NUMBER=41 sh "$work/vmname-build.sh" 2>/dev/null || printf '')
_b=$(JOB_NAME='folderB/main' BUILD_NUMBER=41 sh "$work/vmname-build.sh" 2>/dev/null || printf '')
if [ -n "$_a" ] && [ "$_a" != "$_b" ]; then
	ok "Jenkinsfile: two jobs of two folders get different VM names"
else
	no "Jenkinsfile: two jobs of two folders get different VM names (a='$_a' b='$_b')"
fi
_long=$(JOB_NAME='folderA/a-job-name-that-is-much-longer-than-the-vm-name-rules-allow' \
	BUILD_NUMBER=41 sh "$work/vmname-build.sh" 2>/dev/null || printf '')
if printf '%s' "$_long" | grep -Eq '^[a-z][a-z0-9-]{0,30}$' &&
	printf '%s' "$_long" | grep -Eq '[0-9a-f]{6}$'; then
	ok "Jenkinsfile: a long job name keeps the checksum of the raw name"
else
	no "Jenkinsfile: a long job name keeps the checksum of the raw name (got '$_long')"
fi
_c=$(JOB_NAME='main' BUILD_NUMBER=41 sh "$work/vmname-build.sh" 2>/dev/null || printf '')
if [ -n "$_c" ] && printf '%s' "$_c" | grep -q 'main' && [ "$_a" != "$_c" ]; then
	ok "Jenkinsfile: the folder of the job is part of the VM name"
else
	no "Jenkinsfile: the folder of the job is part of the VM name (a='$_a' c='$_c')"
fi
if jn_sh_code | grep -q 'JOB_NAME' && ! jn_sh_code | grep -q 'JOB_BASE_NAME'; then
	ok "Jenkinsfile: the VM name is built from the full job name"
else
	no "Jenkinsfile: the VM name is built from the full job name"
fi

# (c15) the pipeline runs the test suite before it builds: a tree that
#       fails its own checks must not produce an image.
_stages=$(jn_code | sed -n "s/^[[:space:]]*stage('\([^']*\)').*/\1/p")
_n_test=$(printf '%s\n' "$_stages" | grep -n '^Test$' | cut -d: -f1 | head -1)
_n_build=$(printf '%s\n' "$_stages" | grep -n '^Build$' | cut -d: -f1 | head -1)
if [ -n "$_n_test" ] && [ -n "$_n_build" ] && [ "$_n_test" -lt "$_n_build" ]; then
	ok "Jenkinsfile: the Test stage runs before the Build stage"
else
	no "Jenkinsfile: the Test stage runs before the Build stage"
fi
_testblock=$(jn_block "stage('Test')")
if printf '%s\n' "$_testblock" | grep -q 'tests/run-tests.sh'; then
	ok "Jenkinsfile: the Test stage runs the test suite"
else
	no "Jenkinsfile: the Test stage runs the test suite"
fi

# (c18) the shell of the pipeline is shell: every block of it is checked
#       with sh -n, so that a pipeline that cannot run is caught here and
#       not on a controller.
jn_sh_files "$work/jnsh"
_jn_sh_bad=''
_jn_sh_n=0
for _f in "$work"/jnsh/*.sh; do
	[ -f "$_f" ] || continue
	_jn_sh_n=$((_jn_sh_n + 1))
	sh -n "$_f" 2>/dev/null || _jn_sh_bad="$_jn_sh_bad $(basename "$_f")"
done
if [ "$_jn_sh_n" -gt 0 ] && [ -z "$_jn_sh_bad" ]; then
	ok "Jenkinsfile: every shell block is valid shell"
else
	no "Jenkinsfile: every shell block is valid shell:$_jn_sh_bad"
fi

# (c16) the tap of the guest NIC: opening a tap device creates it outside
#       any bridge and down, so the provider creates the tap, brings it up
#       and adds it to the bridge itself. The ifconfig of the host is
#       replaced by one that logs its arguments and keeps the state of the
#       devices it knows, so that the provider is exercised without a
#       hypervisor and without a tap.
mkdir -p "$work/fakebin" "$work/ifstate"
cat > "$work/fakebin/ifconfig" <<'EOF'
#!/bin/sh
# a fake ifconfig: it logs its arguments and keeps the devices it knows
log=$WTFBSD_FAKE_IFCONFIG_LOG
state=$WTFBSD_FAKE_IFCONFIG_STATE
printf '%s\n' "$*" >> "$log"
dev=$1
shift
op=${1:-}
case $op in
create)
	if [ -n "${WTFBSD_FAKE_IFCONFIG_NO_CREATE:-}" ]; then
		printf 'ifconfig: could not create %s\n' "$dev" >&2
		exit 1
	fi
	printf 'created\n' > "$state/$dev"
	exit 0
	;;
up)
	if [ -n "${WTFBSD_FAKE_IFCONFIG_NO_UP:-}" ] || [ ! -f "$state/$dev" ]; then
		printf 'ifconfig: interface %s does not exist\n' "$dev" >&2
		exit 1
	fi
	printf 'up\n' > "$state/$dev"
	exit 0
	;;
destroy)
	rm -f "$state/$dev"
	exit 0
	;;
addm | deletem)
	member=$2
	if [ "$op" = addm ]; then
		if [ -n "${WTFBSD_FAKE_IFCONFIG_NO_ADDM:-}" ] ||
			[ ! -f "$state/$member" ] || [ "$(cat "$state/$member")" != up ]; then
			printf 'ifconfig: interface %s does not exist\n' "$member" >&2
			exit 1
		fi
		printf 'member\n' > "$state/$dev.$member"
	else
		[ -f "$state/$dev.$member" ] || { printf 'ifconfig: BRDGDEL %s: No such file or directory\n' "$member" >&2; exit 1; }
		rm -f "$state/$dev.$member"
	fi
	exit 0
	;;
esac
# no operation: the device has to exist, and a bridge lists its members the
# way ifconfig(8) does
if [ -f "$state/$dev" ]; then
	printf '%s: flags=8863\n' "$dev"
	for _m in "$state/$dev".*; do
		[ -f "$_m" ] || continue
		_mb=${_m##*/}
		_mb=${_mb#${dev}.}
		printf '\tmember: %s flags=143<LEARNING,DISCOVER,AUTOEDGE,AUTOPTP>\n' "$_mb"
	done
	exit 0
fi
printf 'ifconfig: interface %s does not exist\n' "$dev" >&2
exit 1
EOF
chmod +x "$work/fakebin/ifconfig"
printf '#!/bin/sh\nsleep 30\n' > "$work/fakebin/bhyve"
cat > "$work/fakebin/bhyvectl" <<'EOF'
#!/bin/sh
# a fake bhyvectl: it logs its arguments in the call log of the fake
# ifconfig, so that the order of the calls of the provider can be seen
printf 'bhyvectl %s\n' "$*" >> "${WTFBSD_FAKE_IFCONFIG_LOG:-/dev/null}"
exit 0
EOF
printf '#!/bin/sh\necho 0\n' > "$work/fakebin/id"
printf '#!/bin/sh\nexit 0\n' > "$work/fakebin/kldload"
chmod +x "$work/fakebin/bhyve" "$work/fakebin/bhyvectl" "$work/fakebin/id" "$work/fakebin/kldload"
_wif="$work/ifconfig.log"
_wst="$work/ifstate"
: > "$_wif"
PATH="$work/fakebin:$PATH" WTFBSD_FAKE_IFCONFIG_LOG="$_wif" WTFBSD_FAKE_IFCONFIG_STATE="$_wst" \
	WTFBSD_CONSOLE_DIR="$work/console-tap" WTFBSD_TAP=tap4 WTFBSD_BRIDGE=bridge0 \
	sh "$repo/ci/providers/bhyve.sh" create vmtest "$FIXTURES/fake-image.img" > "$work/tap.log" 2>&1
_rc=$?
if [ -f "$work/console-tap/vmtest.pid" ]; then
	kill "$(cat "$work/console-tap/vmtest.pid")" 2>/dev/null || true
fi
_l_create=$(grep -n '^tap4 create$' "$_wif" 2>/dev/null | head -1 | cut -d: -f1)
_l_up=$(grep -n '^tap4 up$' "$_wif" 2>/dev/null | head -1 | cut -d: -f1)
_l_addm=$(grep -n '^bridge0 addm tap4$' "$_wif" 2>/dev/null | head -1 | cut -d: -f1)
if [ "$_rc" -eq 0 ] && [ -n "$_l_create" ] && [ -n "$_l_up" ] && [ -n "$_l_addm" ] &&
	[ "$_l_create" -lt "$_l_up" ] && [ "$_l_up" -lt "$_l_addm" ]; then
	ok "bhyve provider: the tap is created, brought up and added to the bridge"
else
	no "bhyve provider: the tap is created, brought up and added to the bridge (rc=$_rc)"
fi
# the console reader: the B end of the null-modem pair cannot be opened
# before the guest opens the A end, so the reader is not alive right after
# it was started and the create must not fail because of it
if [ "$_rc" -eq 0 ] && ! grep -qi 'cannot read' "$work/tap.log"; then
	ok "bhyve provider: the create does not wait for the console reader"
else
	no "bhyve provider: the create does not wait for the console reader (rc=$_rc)"
fi
# a tap that cannot be made is fatal: the create fails, it does not go on
# with a network that is not there
: > "$_wif"
PATH="$work/fakebin:$PATH" WTFBSD_FAKE_IFCONFIG_LOG="$_wif" WTFBSD_FAKE_IFCONFIG_STATE="$_wst" \
	WTFBSD_FAKE_IFCONFIG_NO_CREATE=1 WTFBSD_CONSOLE_DIR="$work/console-tap2" \
	WTFBSD_TAP=tap8 WTFBSD_BRIDGE=bridge0 \
	sh "$repo/ci/providers/bhyve.sh" create vmtest2 "$FIXTURES/fake-image.img" > "$work/tap2.log" 2>&1
_rc=$?
if [ "$_rc" -eq 3 ] && grep -qi 'create the tap' "$work/tap2.log" &&
	! grep -q 'addm tap8' "$_wif"; then
	ok "bhyve provider: a tap that cannot be created fails the create"
else
	no "bhyve provider: a tap that cannot be created fails the create (rc=$_rc)"
fi
# the same when the tap cannot be brought up: the tap is not a member of
# the bridge then, and the addm fails
: > "$_wif"
PATH="$work/fakebin:$PATH" WTFBSD_FAKE_IFCONFIG_LOG="$_wif" WTFBSD_FAKE_IFCONFIG_STATE="$_wst" \
	WTFBSD_FAKE_IFCONFIG_NO_UP=1 WTFBSD_CONSOLE_DIR="$work/console-tap3" \
	WTFBSD_TAP=tap5 WTFBSD_BRIDGE=bridge0 \
	sh "$repo/ci/providers/bhyve.sh" create vmtest3 "$FIXTURES/fake-image.img" > "$work/tap3.log" 2>&1
_rc=$?
if [ "$_rc" -eq 3 ] && grep -qi 'the tap tap5 up' "$work/tap3.log" &&
	! grep -q 'addm tap5' "$_wif"; then
	ok "bhyve provider: a tap that cannot be brought up fails the create"
else
	no "bhyve provider: a tap that cannot be brought up fails the create (rc=$_rc)"
fi
# the tap is a member of the bridge: an addm that fails is fatal too
: > "$_wif"
PATH="$work/fakebin:$PATH" WTFBSD_FAKE_IFCONFIG_LOG="$_wif" WTFBSD_FAKE_IFCONFIG_STATE="$_wst" \
	WTFBSD_FAKE_IFCONFIG_NO_ADDM=1 WTFBSD_CONSOLE_DIR="$work/console-tap7" \
	WTFBSD_TAP=tap7 WTFBSD_BRIDGE=bridge0 \
	sh "$repo/ci/providers/bhyve.sh" create vmtest7 "$FIXTURES/fake-image.img" > "$work/tap7.log" 2>&1
_rc=$?
if [ "$_rc" -eq 3 ] && grep -qi 'attach' "$work/tap7.log" && grep -q 'addm tap7' "$_wif"; then
	ok "bhyve provider: a tap that cannot be attached to the bridge fails the create"
else
	no "bhyve provider: a tap that cannot be attached to the bridge fails the create (rc=$_rc)"
fi
# a create that fails after it made the tap leaves no tap behind: the
# tap it made is destroyed again, and its state file is removed
if grep -q '^tap7 destroy$' "$_wif" && [ ! -f "$_wst/tap7" ] && [ ! -f "$work/console-tap7/vmtest7.tap" ]; then
	ok "bhyve provider: a failed attach destroys the tap the create made"
else
	no "bhyve provider: a failed attach destroys the tap the create made"
fi
: > "$_wif"
PATH="$work/fakebin:$PATH" WTFBSD_FAKE_IFCONFIG_LOG="$_wif" WTFBSD_FAKE_IFCONFIG_STATE="$_wst" \
	WTFBSD_FAKE_IFCONFIG_NO_UP=1 WTFBSD_CONSOLE_DIR="$work/console-tap9" \
	WTFBSD_TAP=tap9 WTFBSD_BRIDGE=bridge0 \
	sh "$repo/ci/providers/bhyve.sh" create vmtest9 "$FIXTURES/fake-image.img" > "$work/tap9.log" 2>&1
if grep -q '^tap9 destroy$' "$_wif" && [ ! -f "$_wst/tap9" ]; then
	ok "bhyve provider: a tap that cannot be brought up is destroyed again"
else
	no "bhyve provider: a tap that cannot be brought up is destroyed again"
fi
# a bhyve that exits at once leaves no tap behind either
mkdir -p "$work/deadbin"
printf '#!/bin/sh\nexit 1\n' > "$work/deadbin/bhyve"
chmod +x "$work/deadbin/bhyve"
: > "$_wif"
PATH="$work/deadbin:$work/fakebin:$PATH" WTFBSD_FAKE_IFCONFIG_LOG="$_wif" WTFBSD_FAKE_IFCONFIG_STATE="$_wst" \
	WTFBSD_CONSOLE_DIR="$work/console-tap11" WTFBSD_TAP=tap11 WTFBSD_BRIDGE=bridge0 \
	sh "$repo/ci/providers/bhyve.sh" create vmtest11 "$FIXTURES/fake-image.img" > "$work/tap11.log" 2>&1
_rc=$?
if [ "$_rc" -ne 0 ] && grep -q '^tap11 destroy$' "$_wif" && grep -q '^bridge0 deletem tap11$' "$_wif" &&
	[ ! -f "$_wst/tap11" ] && [ ! -f "$_wst/bridge0.tap11" ]; then
	ok "bhyve provider: a bhyve that exits at once leaves no tap behind"
else
	no "bhyve provider: a bhyve that exits at once leaves no tap behind (rc=$_rc)"
fi

# (c17) the destroy: the tap leaves the bridge again, and a tap that the
#       provider made is destroyed with it. A tap that was already there
#       is only detached.
: > "$_wif"
PATH="$work/fakebin:$PATH" WTFBSD_FAKE_IFCONFIG_LOG="$_wif" WTFBSD_FAKE_IFCONFIG_STATE="$_wst" \
	WTFBSD_CONSOLE_DIR="$work/console-tap" WTFBSD_TAP=tap4 WTFBSD_BRIDGE=bridge0 \
	sh "$repo/ci/providers/bhyve.sh" destroy vmtest > "$work/tap4.log" 2>&1
_rc=$?
_l_del=$(grep -n '^bridge0 deletem tap4$' "$_wif" 2>/dev/null | head -1 | cut -d: -f1)
_l_des=$(grep -n '^tap4 destroy$' "$_wif" 2>/dev/null | head -1 | cut -d: -f1)
if [ "$_rc" -eq 0 ] && [ -n "$_l_del" ] && [ -n "$_l_des" ] && [ "$_l_del" -lt "$_l_des" ]; then
	ok "bhyve provider: the destroy detaches the tap and destroys the tap it made"
else
	no "bhyve provider: the destroy detaches the tap and destroys the tap it made (rc=$_rc)"
fi
# a tap that the provider did not make is left alone
printf 'up\n' > "$_wst/tap6"
: > "$_wif"
PATH="$work/fakebin:$PATH" WTFBSD_FAKE_IFCONFIG_LOG="$_wif" WTFBSD_FAKE_IFCONFIG_STATE="$_wst" \
	WTFBSD_CONSOLE_DIR="$work/console-tap4" WTFBSD_TAP=tap6 WTFBSD_BRIDGE=bridge0 \
	sh "$repo/ci/providers/bhyve.sh" create vmtest4 "$FIXTURES/fake-image.img" > "$work/tap5.log" 2>&1
_rc=$?
: > "$_wif"
PATH="$work/fakebin:$PATH" WTFBSD_FAKE_IFCONFIG_LOG="$_wif" WTFBSD_FAKE_IFCONFIG_STATE="$_wst" \
	WTFBSD_CONSOLE_DIR="$work/console-tap4" WTFBSD_TAP=tap6 WTFBSD_BRIDGE=bridge0 \
	sh "$repo/ci/providers/bhyve.sh" destroy vmtest4 > "$work/tap6.log" 2>&1
_rc=$?
if [ "$_rc" -eq 0 ] && grep -q '^bridge0 deletem tap6$' "$_wif" &&
	! grep -q '^tap6 destroy$' "$_wif"; then
	ok "bhyve provider: a tap the provider did not make is only detached"
else
	no "bhyve provider: a tap the provider did not make is only detached (rc=$_rc)"
fi

# (c17a) the destroy stops the VM before it takes the tap away: the NIC of
#        a running guest is not taken away from under it, and a destroy
#        that fails leaves the VM and its tap alone. The calls of the
#        provider, of the fake ifconfig and of the fake bhyvectl all go
#        into one file, so that the order of them can be seen.
_orddir="$work/console-order"
mkdir -p "$_orddir" "$work/devices"
: > "$work/devices/vmtest"
_calllog="$work/call-order.log"
: > "$_calllog"
PATH="$work/fakebin:$PATH" WTFBSD_FAKE_IFCONFIG_LOG="$_calllog" WTFBSD_FAKE_IFCONFIG_STATE="$_wst" \
	WTFBSD_CONSOLE_DIR="$_orddir" WTFBSD_TAP=tap11 WTFBSD_BRIDGE=bridge0 \
	sh "$repo/ci/providers/bhyve.sh" create vmtest "$FIXTURES/fake-image.img" > "$work/order-create.log" 2>&1
_rc=$?
if [ -f "$_orddir/vmtest.pid" ]; then
	kill "$(cat "$_orddir/vmtest.pid")" 2>/dev/null || true
fi
sleep 30 &
_ordreader=$!
printf '%s\n' "$_ordreader" > "$_orddir/vmtest.reader.pid"
: > "$_calllog"
PATH="$work/fakebin:$PATH" WTFBSD_FAKE_IFCONFIG_LOG="$_calllog" WTFBSD_FAKE_IFCONFIG_STATE="$_wst" \
	WTFBSD_CONSOLE_DIR="$_orddir" WTFBSD_VM_DEVICE_DIR="$work/devices" \
	sh "$repo/ci/providers/bhyve.sh" destroy vmtest 2>>"$_calllog" >/dev/null
_rc=$?
wait "$_ordreader" 2>/dev/null || true
_l_ctl=$(grep -n '^bhyvectl --destroy --vm=vmtest$' "$_calllog" 2>/dev/null | head -1 | cut -d: -f1)
_l_rdr=$(grep -n 'console reader' "$_calllog" 2>/dev/null | head -1 | cut -d: -f1)
_l_del=$(grep -n '^bridge0 deletem tap11$' "$_calllog" 2>/dev/null | head -1 | cut -d: -f1)
_l_des=$(grep -n '^tap11 destroy$' "$_calllog" 2>/dev/null | head -1 | cut -d: -f1)
if [ "$_rc" -eq 0 ] && [ -n "$_l_ctl" ] && [ -n "$_l_rdr" ] && [ -n "$_l_del" ] &&
	[ -n "$_l_des" ] && [ "$_l_ctl" -lt "$_l_rdr" ] && [ "$_l_rdr" -lt "$_l_del" ] &&
	[ "$_l_del" -lt "$_l_des" ]; then
	ok "bhyve provider: the destroy stops the VM, then the reader, then the tap"
else
	no "bhyve provider: the destroy stops the VM, then the reader, then the tap (rc=$_rc)"
fi

# (c17b) the tap the provider used is the tap the destroy takes away: the
#        names are written down at the create, and the destroy uses them
#        and not the ones the environment holds at that time. Without the
#        executor number of the job the tap falls back to tap0, and the
#        destroy would take away a tap of the host.
_ex3="$work/console-exec3"
mkdir -p "$_ex3"
: > "$_wif"
PATH="$work/fakebin:$PATH" WTFBSD_FAKE_IFCONFIG_LOG="$_wif" WTFBSD_FAKE_IFCONFIG_STATE="$_wst" \
	EXECUTOR_NUMBER=3 WTFBSD_CONSOLE_DIR="$_ex3" \
	sh "$repo/ci/providers/bhyve.sh" create vmtest "$FIXTURES/fake-image.img" > "$work/exec3.log" 2>&1
_rc=$?
if [ -f "$_ex3/vmtest.pid" ]; then
	kill "$(cat "$_ex3/vmtest.pid")" 2>/dev/null || true
fi
if grep -q '^tap=tap3$' "$_ex3/vmtest.tap" 2>/dev/null &&
	grep -q '^bridge=bridge0$' "$_ex3/vmtest.tap" 2>/dev/null &&
	grep -q '^created=yes$' "$_ex3/vmtest.tap" 2>/dev/null; then
	ok "bhyve provider: the tap state file names the tap, the bridge and who made it"
else
	no "bhyve provider: the tap state file names the tap, the bridge and who made it"
fi
: > "$_wif"
PATH="$work/fakebin:$PATH" WTFBSD_FAKE_IFCONFIG_LOG="$_wif" WTFBSD_FAKE_IFCONFIG_STATE="$_wst" \
	WTFBSD_CONSOLE_DIR="$_ex3" \
	sh "$repo/ci/providers/bhyve.sh" destroy vmtest > "$work/exec3-destroy.log" 2>&1
_rc=$?
if grep -q '^bridge0 deletem tap3$' "$_wif" 2>/dev/null &&
	grep -q '^tap3 destroy$' "$_wif" 2>/dev/null &&
	! grep -q 'tap0' "$_wif" 2>/dev/null; then
	ok "bhyve provider: the destroy takes away the tap of the create, not the tap of the environment"
else
	no "bhyve provider: the destroy takes away the tap of the create, not the tap of the environment (rc=$_rc)"
fi

# (c17c) a reader pid file that holds 0 must not make the provider signal
#        its own process group: kill(2) with 0 reaches every process of
#        the group of the caller. The provider runs in a session of its
#        own here, so that a signal that got out is seen, and so that it
#        does not reach the suite.
if command -v setsid >/dev/null 2>&1; then
	_pid0dir="$work/console-pid0"
	mkdir -p "$_pid0dir"
	printf '0\n' > "$_pid0dir/vmtest.reader.pid"
	_rc=0
	WTFBSD_CONSOLE_DIR="$_pid0dir" setsid sh -c \
		'PATH="$1:$PATH"; export PATH; exec sh "$2" destroy vmtest' \
		wtfbsd "$work/fakebin" "$repo/ci/providers/bhyve.sh" > "$work/pid0.log" 2>&1 || _rc=$?
	if [ "$_rc" -eq 0 ]; then
		ok "bhyve provider: a reader pid file of 0 does not signal the process group"
	else
		no "bhyve provider: a reader pid file of 0 does not signal the process group (rc=$_rc)"
	fi
	# the same for a pid file that holds nothing at all
	_pid0dir="$work/console-pidempty"
	mkdir -p "$_pid0dir"
	: > "$_pid0dir/vmtest.reader.pid"
	_rc=0
	WTFBSD_CONSOLE_DIR="$_pid0dir" setsid sh -c \
		'PATH="$1:$PATH"; export PATH; exec sh "$2" destroy vmtest' \
		wtfbsd "$work/fakebin" "$repo/ci/providers/bhyve.sh" > "$work/pidempty.log" 2>&1 || _rc=$?
	if [ "$_rc" -eq 0 ]; then
		ok "bhyve provider: a reader pid file that is empty does not signal anything"
	else
		no "bhyve provider: a reader pid file that is empty does not signal anything (rc=$_rc)"
	fi
else
	ok "bhyve provider: a reader pid file of 0 does not signal the process group (not run: no setsid)"
fi

# (c19) a tap that is already a member of the bridge: a run that died hard
#       leaves the tap in the bridge, and ifconfig(8) refuses an addm of a
#       member that is already there (EEXIST). The member list of the
#       bridge is read first, and the addm is skipped when the tap is
#       already one of them.
printf 'up\n' > "$_wst/tap9"
printf 'up\n' > "$_wst/bridge1"
printf 'member\n' > "$_wst/bridge1.tap9"
: > "$_wif"
PATH="$work/fakebin:$PATH" WTFBSD_FAKE_IFCONFIG_LOG="$_wif" WTFBSD_FAKE_IFCONFIG_STATE="$_wst" \
	WTFBSD_CONSOLE_DIR="$work/console-tap9" WTFBSD_TAP=tap9 WTFBSD_BRIDGE=bridge1 \
	sh "$repo/ci/providers/bhyve.sh" create vmtest9 "$FIXTURES/fake-image.img" > "$work/tap9.log" 2>&1
_rc=$?
if [ -f "$work/console-tap9/vmtest9.pid" ]; then
	kill "$(cat "$work/console-tap9/vmtest9.pid")" 2>/dev/null || true
fi
if [ "$_rc" -eq 0 ] && grep -q '^bridge1$' "$_wif" &&
	! grep -q '^bridge1 addm tap9$' "$_wif"; then
	ok "bhyve provider: a tap that is already a member of the bridge is not added again"
else
	no "bhyve provider: a tap that is already a member of the bridge is not added again (rc=$_rc)"
fi

# (d4) the sshd wait is bounded: the connect gets a timeout, so that an
#       address that swallows packets cannot hang the build.
if grep -F 'nc -z -w 2' "$repo/tests/boot-test.sh" >/dev/null 2>&1; then
	ok "boot test: the sshd wait has a bounded connect"
else
	no "boot test: the sshd wait has a bounded connect"
fi

# (d) the boot test passes when the serial console reaches a login prompt.
#      The VM gets a name of its own, so that the check (f) below can tell
#      the log of this run from the logs of the other runs.
_okname=boot-desktop-ok
_calls="$work/calls-ok.log"
_msg=$(WTFBSD_VM_PROVIDER_PATH="$FAKE" WTFBSD_FAKE_CALL_LOG="$_calls" \
	WTFBSD_FAKE_CONSOLE_LOG="$FIXTURES/serial-login.log" \
	WTFBSD_FAKE_CONSOLE_DIR="$work/console-ok" \
	sh "$BOOTSH" "$FIXTURES/fake-image.img" desktop "$_okname" 2>&1); _rc=$?
if [ "$_rc" -eq 0 ]; then
	ok "boot test: fake provider, serial login prompt reached (desktop)"
else
	no "boot test: fake provider, serial login prompt reached (rc=$_rc)"
fi

# (d2) the appliance profile also waits for sshd to answer on the port
_port=$((42000 + $$ % 1000))
( nc -l 127.0.0.1 "$_port" >/dev/null 2>&1 & echo $! > "$work/nc.pid" )
sleep 1
_ncpid=$(cat "$work/nc.pid" 2>/dev/null || printf '')
if [ -n "$_ncpid" ] && kill -0 "$_ncpid" 2>/dev/null; then
	_calls3="$work/calls-appliance.log"
	_msg=$(SSH_PORT="$_port" BOOT_TIMEOUT=5 WTFBSD_VM_PROVIDER_PATH="$FAKE" \
		WTFBSD_FAKE_CALL_LOG="$_calls3" \
		WTFBSD_FAKE_CONSOLE_LOG="$FIXTURES/serial-login.log" \
		WTFBSD_FAKE_CONSOLE_DIR="$work/console-appliance" \
		sh "$BOOTSH" "$FIXTURES/fake-image.img" appliance 2>&1); _rc=$?
	kill "$_ncpid" 2>/dev/null || true
	if [ "$_rc" -eq 0 ]; then
		ok "boot test: appliance profile waits for sshd on the port"
	else
		no "boot test: appliance profile waits for sshd on the port (rc=$_rc)"
	fi
else
	kill "$_ncpid" 2>/dev/null || true
	no "boot test: appliance profile waits for sshd on the port (no listener on port $_port)"
fi

# (d3) the appliance profile also waits for sshd: with a login prompt on the
#      serial console but nothing listening on the port, the boot test must
#      fail and say that sshd is what it waited for.
_port2=$((43000 + $$ % 1000))
while nc -z 127.0.0.1 "$_port2" >/dev/null 2>&1; do
	_port2=$((_port2 + 1))
done
_calls6="$work/calls-nosshd.log"
_msg=$(SSH_PORT="$_port2" BOOT_TIMEOUT=3 WTFBSD_VM_PROVIDER_PATH="$FAKE" \
	WTFBSD_FAKE_CALL_LOG="$_calls6" \
	WTFBSD_FAKE_CONSOLE_LOG="$FIXTURES/serial-login.log" \
	WTFBSD_FAKE_CONSOLE_DIR="$work/console-nosshd" \
	sh "$BOOTSH" "$FIXTURES/fake-image.img" appliance 2>&1); _rc=$?
if [ "$_rc" -ne 0 ] && printf '%s' "$_msg" | grep -qi 'sshd'; then
	ok "boot test: the appliance profile fails when sshd does not answer"
else
	no "boot test: the appliance profile fails when sshd does not answer (rc=$_rc)"
fi

# (d5) the address the provider hands out has to be an address: the boot
#      test refuses one that is not, and it takes the bracketed IPv6 form.
#      The provider here hands out the address it is given, so that every
#      form can be tried.
cat > "$work/addr-provider.sh" <<'EOF'
#!/bin/sh
# a provider that hands out the address in WTFBSD_FAKE_ADDR
case $1 in
create)
	mkdir -p "$WTFBSD_FAKE_CONSOLE_DIR"
	cp "$WTFBSD_FAKE_CONSOLE_LOG" "$WTFBSD_FAKE_CONSOLE_DIR/$2.log"
	printf '%s\n' "$WTFBSD_FAKE_CONSOLE_DIR/$2.log" > "$WTFBSD_FAKE_CONSOLE_DIR/$2.path"
	;;
console) cat "$WTFBSD_FAKE_CONSOLE_DIR/$2.path" ;;
addr)
	if [ -n "${WTFBSD_FAKE_ADDR_FAIL:-}" ]; then
		printf 'the provider cannot answer\n' >&2
		exit 1
	fi
	printf '%s\n' "$WTFBSD_FAKE_ADDR"
	;;
destroy) : ;;
esac
exit 0
EOF
chmod +x "$work/addr-provider.sh"
# the set of the characters an address may hold: a bracket is only the
# wrapper of the IPv6 form, and it is not a character of an address
_addrbad=''
for _a in 'a;b' '-x' 'a]b' 'a[b'; do
	_msg=$(BOOT_TIMEOUT=3 WTFBSD_VM_PROVIDER_PATH="$work/addr-provider.sh" \
		WTFBSD_FAKE_ADDR="$_a" WTFBSD_FAKE_CONSOLE_LOG="$FIXTURES/serial-login.log" \
		WTFBSD_FAKE_CONSOLE_DIR="$work/console-addr-bad" \
		sh "$BOOTSH" "$FIXTURES/fake-image.img" appliance 2>&1); _rc=$?
	if [ "$_rc" -eq 0 ] || ! printf '%s' "$_msg" | grep -q 'not an address'; then
		_addrbad="$_addrbad [$_a]"
	fi
done
if [ -z "$_addrbad" ]; then
	ok "boot test: an address that is not an address is refused"
else
	no "boot test: an address that is not an address is refused:$_addrbad"
fi
_addrbad=''
for _a in '[::1]' '192.0.2.5'; do
	_msg=$(BOOT_TIMEOUT=3 WTFBSD_VM_PROVIDER_PATH="$work/addr-provider.sh" \
		WTFBSD_FAKE_ADDR="$_a" WTFBSD_FAKE_CONSOLE_LOG="$FIXTURES/serial-login.log" \
		WTFBSD_FAKE_CONSOLE_DIR="$work/console-addr-ok" \
		sh "$BOOTSH" "$FIXTURES/fake-image.img" appliance 2>&1); _rc=$?
	if printf '%s' "$_msg" | grep -q 'not an address'; then
		_addrbad="$_addrbad [$_a]"
	fi
done
if [ -z "$_addrbad" ]; then
	ok "boot test: the bracketed IPv6 form and a plain address are accepted"
else
	no "boot test: the bracketed IPv6 form and a plain address are accepted:$_addrbad"
fi
# a provider that cannot answer with an address fails the boot test, and
# the boot test says that it is the address that is missing
_msg=$(BOOT_TIMEOUT=3 WTFBSD_VM_PROVIDER_PATH="$work/addr-provider.sh" \
	WTFBSD_FAKE_ADDR_FAIL=1 WTFBSD_FAKE_CONSOLE_LOG="$FIXTURES/serial-login.log" \
	WTFBSD_FAKE_CONSOLE_DIR="$work/console-addr-fail" \
	sh "$BOOTSH" "$FIXTURES/fake-image.img" appliance 2>&1); _rc=$?
if [ "$_rc" -ne 0 ] && printf '%s' "$_msg" | grep -q 'returned no address'; then
	ok "boot test: a provider that returns no address fails the boot test"
else
	no "boot test: a provider that returns no address fails the boot test (rc=$_rc)"
fi

# (e) the same boot fails within the timeout when no login prompt appears
_calls2="$work/calls-timeout.log"
_t0=$(date +%s)
_msg=$(BOOT_TIMEOUT=3 WTFBSD_VM_PROVIDER_PATH="$FAKE" WTFBSD_FAKE_CALL_LOG="$_calls2" \
	WTFBSD_FAKE_CONSOLE_LOG="$FIXTURES/serial-nologin.log" \
	WTFBSD_FAKE_CONSOLE_DIR="$work/console-timeout" \
	sh "$BOOTSH" "$FIXTURES/fake-image.img" desktop 2>&1); _rc=$?
_t1=$(date +%s)
if [ "$_rc" -ne 0 ] && [ $((_t1 - _t0)) -lt 60 ] && printf '%s' "$_msg" | grep -q 'timed out'; then
	ok "boot test: no login prompt fails within the timeout"
else
	no "boot test: no login prompt fails within the timeout (rc=$_rc, $((_t1 - _t0))s)"
fi

# (e2) an interrupted boot test destroys the VM it created and fails
_calls7="$work/calls-signal.log"
BOOT_TIMEOUT=60 WTFBSD_VM_PROVIDER_PATH="$FAKE" WTFBSD_FAKE_CALL_LOG="$_calls7" \
	WTFBSD_FAKE_CONSOLE_LOG="$FIXTURES/serial-nologin.log" \
	WTFBSD_FAKE_CONSOLE_DIR="$work/console-signal" \
	sh "$BOOTSH" "$FIXTURES/fake-image.img" desktop > "$work/signal.out" 2>&1 &
_pid=$!
sleep 1
kill -TERM "$_pid" 2>/dev/null || true
_rc=0
wait "$_pid" || _rc=$?
if [ "$_rc" -ne 0 ] && grep -q '^destroy ' "$_calls7" 2>/dev/null; then
	ok "boot test: an interrupted boot test destroys the VM and fails"
else
	kill -TERM "$_pid" 2>/dev/null || true
	no "boot test: an interrupted boot test destroys the VM and fails (rc=$_rc)"
fi

# (e2b) the same for INT and HUP. The boot test runs in the foreground
#       here: the shell of a test ignores SIGINT in a background job, and
#       a signal that was ignored on entry cannot be trapped. A helper
#       sends the signal to the boot test instead.
for _sig in INT HUP; do
	case $_sig in
	INT) _want=130 ;;
	HUP) _want=129 ;;
	esac
	_pf="$work/boot-$_sig.pid"
	_calls_sig="$work/calls-signal-$_sig.log"
	rm -f "$_pf"
	( sleep 1; kill -"$_sig" "$(cat "$_pf" 2>/dev/null || printf 0)" 2>/dev/null || true ) &
	_sender=$!
	BOOT_TIMEOUT=60 WTFBSD_VM_PROVIDER_PATH="$FAKE" WTFBSD_FAKE_CALL_LOG="$_calls_sig" \
		WTFBSD_FAKE_CONSOLE_LOG="$FIXTURES/serial-nologin.log" \
		WTFBSD_FAKE_CONSOLE_DIR="$work/console-signal-$_sig" \
		sh -c 'echo $$ > "$0"; exec sh "$1" "$2" "$3"' "$_pf" "$BOOTSH" \
		"$FIXTURES/fake-image.img" desktop > "$work/signal-$_sig.out" 2>&1
	_rc=$?
	wait "$_sender" 2>/dev/null || true
	# the status has to be the one of the signal: a boot test that ran
	# into its timeout exits 1, and that is not the same thing
	if [ "$_rc" -eq "$_want" ] && grep -q '^destroy ' "$_calls_sig" 2>/dev/null; then
		ok "boot test: an interrupted boot test ($_sig) destroys the VM and fails"
	else
		no "boot test: an interrupted boot test ($_sig) destroys the VM and fails (rc=$_rc, wanted $_want)"
	fi
done

# (e3) a boot test whose destroy fails says so AND fails: the failure must
#      not be swallowed, or a leaked VM looks like a clean run.
cat > "$work/failing-provider.sh" <<'EOF'
#!/bin/sh
# a provider whose destroy always fails
case $1 in
create)
	mkdir -p "$WTFBSD_FAKE_CONSOLE_DIR"
	cp "$WTFBSD_FAKE_CONSOLE_LOG" "$WTFBSD_FAKE_CONSOLE_DIR/$2.log"
	printf '%s\n' "$WTFBSD_FAKE_CONSOLE_DIR/$2.log" > "$WTFBSD_FAKE_CONSOLE_DIR/$2.path"
	;;
console) cat "$WTFBSD_FAKE_CONSOLE_DIR/$2.path" ;;
addr) printf '127.0.0.1\n' ;;
destroy) printf 'failing provider: the VM is still there\n' >&2; exit 3 ;;
esac
exit 0
EOF
chmod +x "$work/failing-provider.sh"
_msg=$(WTFBSD_VM_PROVIDER_PATH="$work/failing-provider.sh" \
	WTFBSD_FAKE_CONSOLE_LOG="$FIXTURES/serial-login.log" \
	WTFBSD_FAKE_CONSOLE_DIR="$work/console-failing" \
	sh "$BOOTSH" "$FIXTURES/fake-image.img" desktop 2>&1); _rc=$?
if [ "$_rc" -ne 0 ] && printf '%s' "$_msg" | grep -q 'destroy failed' &&
	printf '%s' "$_msg" | grep -q 'may still be running'; then
	ok "boot test: a failing destroy fails the boot test"
else
	no "boot test: a failing destroy fails the boot test (rc=$_rc)"
fi

# (f) the VM is destroyed in both runs, and it is the VM that was created.
#      The log of the successful run is the one that is read here: the
#      name of the VM of that run is the one of the run (d), so that a
#      check that reads the log of another run cannot pass by accident.
_created=$(sed -n 's/^create \([^ ]*\) .*/\1/p' "$_calls" 2>/dev/null | head -1)
_destroyed=$(sed -n 's/^destroy //p' "$_calls" 2>/dev/null | head -1)
if [ -n "$_created" ] && [ "$_created" = "$_destroyed" ] && [ "$_created" = "$_okname" ]; then
	ok "boot test: the created VM is destroyed after a successful boot"
else
	no "boot test: the created VM is destroyed after a successful boot (created=$_created destroyed=$_destroyed)"
fi
_created2=$(sed -n 's/^create \([^ ]*\) .*/\1/p' "$_calls2" 2>/dev/null | head -1)
_destroyed2=$(sed -n 's/^destroy //p' "$_calls2" 2>/dev/null | head -1)
if [ -n "$_created2" ] && [ "$_created2" = "$_destroyed2" ]; then
	ok "boot test: the created VM is destroyed after a failed boot"
else
	no "boot test: the created VM is destroyed after a failed boot (created=$_created2 destroyed=$_destroyed2)"
fi

# (f1) the check (f) is about the successful run: when the boot test no
#      longer destroys the VM it created, the check has to fail. The suite
#      is run against a copy of the tree in which the destroy of the boot
#      test is taken out, and the check has to fail there.
if [ -n "${WTFBSD_NO_SUITE_RUN:-}" ]; then
	ok "boot test: the check of the successful run fails when the destroy is taken out (not run: this is the suite)"
else
	_mut="$work/mutant"
	mkdir -p "$_mut"
	cp -R "$repo/." "$_mut/"
	sed 's|if ! sh "$VM" destroy "$name" >/dev/null; then|if false; then|' \
		"$_mut/tests/boot-test.sh" > "$_mut/tests/boot-test.sh.new"
	mv "$_mut/tests/boot-test.sh.new" "$_mut/tests/boot-test.sh"
	if grep -q 'if false; then' "$_mut/tests/boot-test.sh" 2>/dev/null; then
		WTFBSD_NO_SUITE_RUN=1 WTFBSD_REPO="$_mut" sh "$_mut/tests/run-tests.sh" > "$work/mutant.log" 2>&1
		_mutrc=$?
		if grep -q 'FAIL  boot test: the created VM is destroyed after a successful boot' "$work/mutant.log" 2>/dev/null; then
			ok "boot test: the check of the successful run fails when the destroy is taken out"
		else
			no "boot test: the check of the successful run fails when the destroy is taken out (rc=$_mutrc)"
		fi
	else
		no "boot test: the check of the successful run fails when the destroy is taken out (the mutation did not take)"
	fi
fi

# (g) the pipeline drives ci/vm.sh, never a vm(8) subcommand
if grep -Eq 'vm[[:space:]]+(create|start|destroy)' "$repo/Jenkinsfile"; then
	no "Jenkinsfile: no vm create / vm start / vm destroy"
else
	ok "Jenkinsfile: no vm create / vm start / vm destroy"
fi

# (h) opencode.json is valid JSON and names no provider, model, key or MCP server
if command -v python3 >/dev/null 2>&1; then
	if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$repo/opencode.json" >/dev/null 2>&1; then
		ok "opencode.json parses as JSON"
	else
		no "opencode.json parses as JSON"
	fi
else
	if [ -f "$repo/opencode.json" ] && head -c 1 "$repo/opencode.json" | grep -q '{'; then
		ok "opencode.json parses as JSON (no python3; structural check only)"
	else
		no "opencode.json parses as JSON (no python3; structural check only)"
	fi
fi
if [ -f "$repo/opencode.json" ] && ! grep -Eiq "$_nokeys" "$repo/opencode.json"; then
	ok "opencode.json names no provider, model, key or MCP server"
else
	no "opencode.json names no provider, model, key or MCP server"
fi
for _a in builder tester; do
	if [ -f "$repo/.opencode/agent/$_a.md" ] && grep -q '^description:' "$repo/.opencode/agent/$_a.md" \
		&& grep -q '^mode: subagent' "$repo/.opencode/agent/$_a.md"; then
		ok "opencode agent $_a.md declares a description and mode: subagent"
	else
		no "opencode agent $_a.md declares a description and mode: subagent"
	fi
done

# (i) no_internal_refs: the shipped tree carries no key material, no token
#     and no address that is not a documented placeholder.
#
#     The PUBLIC half of the check looks for generic shapes only. It must
#     never name what it looks for: a list of the names that must not be
#     published is itself a publication of them, and a name split into
#     fragments is the same publication with extra steps. The shapes below
#     are the shapes of a secret, never the name of a company, and no file
#     of this repository holds a list of names.
#
#     The PRIVATE half is optional and lives outside the repository: point
#     $WTFBSD_DENYLIST at a readable file and every non-comment line of
#     that file is used as a case-insensitive extended regular expression
#     against every file of the tree. The repository ships no such file.
#
# The shapes. A shape whose text would appear literally in this file is
# written from fragments (see _frag above), so the check never matches its
# own source.
IPS='[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'
IPV6='(^|[^0-9A-Za-z:])(([0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}|([0-9A-Fa-f]{1,4}:){1,7}:|([0-9A-Fa-f]{1,4}:){1,6}:[0-9A-Fa-f]{1,4}|([0-9A-Fa-f]{1,4}:){1,5}(:[0-9A-Fa-f]{1,4}){1,2}|([0-9A-Fa-f]{1,4}:){1,4}(:[0-9A-Fa-f]{1,4}){1,3}|([0-9A-Fa-f]{1,4}:){1,3}(:[0-9A-Fa-f]{1,4}){1,4}|([0-9A-Fa-f]{1,4}:){1,2}(:[0-9A-Fa-f]{1,4}){1,5}|[0-9A-Fa-f]{1,4}:((:[0-9A-Fa-f]{1,4}){1,6})|:((:[0-9A-Fa-f]{1,4}){1,7}|:))([^0-9A-Za-z:]|$)'
IPV6C='[0-9A-Fa-f]{0,4}(:[0-9A-Fa-f]{0,4}){2,7}'
EMAIL='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
# An internal top level domain, on a label that is not part of a path: the
# tree holds paths like etc/rc.local and usr/local, which are not hosts.
# The home.arpa domain is the one a home network uses by convention.
TLD='(^|[^A-Za-z0-9_./-])[A-Za-z0-9-]+\.(lan|corp|internal|local|lab|home\.arpa)([^A-Za-z0-9-]|$)'
KEYS="$(_frag 'BEG' 'IN ').*$(_frag 'PRIVA' 'TE KEY')|$(_frag 'ssh-' '(ed25519|rsa)') AAAA"
# A token of a hosted service. The dashes count as well: the keys of some
# services carry a prefix and a group of dashes.
TOKENS="$(_frag 'gh' 'p_')|$(_frag 'gh' 'o_')|$(_frag 'git' 'hub_pat_')|$(_frag 'AK' 'IA')[0-9A-Z]{16}|$(_frag 'xox' '[abp]-')|$(_frag 's' 'k-')[A-Za-z0-9_-]{20,}"
SECRETS="$(_frag 'api' 'Key')|$(_frag 'api' '_key')|$(_frag 'base' 'URL')|$(_frag 'Bea' 'rer')"
SHAPES="$KEYS|$TOKENS|$SECRETS|$TLD|$IPS|$EMAIL|$IPV6C"
# The documented exceptions. An address is allowed as a whole address only:
# an address that merely starts like the loopback placeholder is not it.
# The documentation ranges are the three IPv4 ranges and one IPv6 range
# that RFC 5737 and RFC 3849 set aside for examples.
ALLOW_IP='127.0.0.1'
ALLOW_IP6='::1'
# The domains of the allowed e-mail addresses: the two placeholder domains.
ALLOW_MAIL_DOMAIN='example.org example.com'
# The domain the OpenSSH key types carry as their suffix, and the shape of
# their local part. A key type such as the security key algorithm is
# shaped like an e-mail address, and the product code keeps the exact key
# types: only a key type is exempt on that domain, every other address
# there is a leak like any other.
KEYTYPE_MAIL_DOMAIN='openssh.com'
KEYTYPE_MAIL_PREFIX='sk-'

# The tree the leak check reads: the tree of the repository, or a copy of
# it. The probe of the artifacts of a CI run reads a copy, so that the
# working tree is never written to.
leak_root=$repo

# tree_files — the files of the tree, NUL separated
tree_files() {
	if command -v git >/dev/null 2>&1 && [ -d "$leak_root/.git" ]; then
		git -C "$leak_root" ls-files -z --cached --others --exclude-standard 2>/dev/null
	else
		# the same files .gitignore keeps out of git are left out here
		( cd "$leak_root" && find . -type f -not -path './.git/*' -not -path './console-logs/*' \
			-not -name product.conf -not -name PRODUCT_CONF -not -name '.wtfbsd-*' \
			-not -name 'ROUND-REPORT*.md' -print0 2>/dev/null )
	fi
}

# tree_names — the files of the tree, one name per line. The list is read
# NUL separated and walked with xargs -0, so a name with a space in it is
# one name and not two.
tree_names() {
	tree_files | xargs -0 -n1 printf '%s\n' 2>/dev/null || true
}

# (i6) a tree that is not a git checkout has no ignore rules: the files that
#      .gitignore keeps out of git (the site's own product.conf, the CI run's
#      files, round reports) are left out of the scan there too.
_ng=$(mktemp -d)
mkdir -p "$_ng/console-logs"
for _f in a.txt product.conf PRODUCT_CONF console-logs/x.addr .wtfbsd-vms ROUND-REPORT-2.md; do
	printf 'x\n' > "$_ng/$_f"
done
_ng_list=$(leak_root=$_ng tree_names | sort | tr '\n' ' ')
rm -rf "$_ng"
if [ "$_ng_list" = './a.txt ' ]; then
	ok "outside a git checkout the leak scan skips the files git ignores"
else
	no "outside a git checkout the leak scan skips the files git ignores (got: $_ng_list)"
fi

# (j10) the Jenkinsfile: the first build of a new job (no parameter set)
#       fails with a message instead of an unset-variable error, the path
#       check refuses '/', and scp gets an IPv6 address in brackets
_first=$(sed -n '/set -eu/,/^\t\t\t\t\t# API-triggered/p' "$repo/Jenkinsfile" | sed -n '1,/fi$/p')
_fmsg=$( (unset PROFILE; eval "$_first") 2>&1); _frc=$?
if [ "$_frc" -eq 1 ] && printf '%s' "$_fmsg" | grep -q 'build again with parameters'; then
	ok "Jenkinsfile: the first build of a new job says to build again with parameters"
else
	no "Jenkinsfile: the first build of a new job says to build again with parameters (rc=$_frc: $_fmsg)"
fi
_crp=$(sed -n '/^check_remote_path() {/,/^}/p' "$repo/Jenkinsfile")
if (eval "$_crp"; check_remote_path /usr/src X) 2>/dev/null && ! (eval "$_crp"; check_remote_path / X) 2>/dev/null; then
	ok "Jenkinsfile: a remote path of '/' alone is refused"
else
	no "Jenkinsfile: a remote path of '/' alone is refused"
fi
if grep -q '"\$raddr:\$build_dir/product.conf"' "$repo/Jenkinsfile" && grep -q '\*:\*) raddr="\[\$addr\]"' "$repo/Jenkinsfile" &&
	! grep -q '"\$addr:\$build_dir' "$repo/Jenkinsfile"; then
	ok "Jenkinsfile: scp gets an IPv6 address of the build VM in brackets"
else
	no "Jenkinsfile: scp gets an IPv6 address of the build VM in brackets"
fi

# (j9) the Jenkinsfile accepts an empty provider name when a provider path
#      is given (ci/vm.sh: the path wins), and refuses when neither is set
_vp=$(sed -n '/case \$WTFBSD_VM_PROVIDER in/,/esac/p' "$repo/Jenkinsfile")
if (WTFBSD_VM_PROVIDER='' WTFBSD_VM_PROVIDER_PATH=/x/p.sh; eval "$_vp") > /dev/null 2>&1 &&
	! (WTFBSD_VM_PROVIDER='' WTFBSD_VM_PROVIDER_PATH=''; eval "$_vp") > /dev/null 2>&1 &&
	! (WTFBSD_VM_PROVIDER='a b' WTFBSD_VM_PROVIDER_PATH=''; eval "$_vp") > /dev/null 2>&1; then
	ok "Jenkinsfile: an empty provider name is accepted only with a provider path"
else
	no "Jenkinsfile: an empty provider name is accepted only with a provider path"
fi

# allowed_ip — the address is one of the documented placeholders
allowed_ip() {
	[ "$1" = "$ALLOW_IP" ] && return 0
	case $1 in
	192.0.2.* | 198.51.100.* | 203.0.113.*) return 0 ;;
	esac
	return 1
}

# allowed_ip6 — the address is one of the documented placeholders
allowed_ip6() {
	[ "$1" = "$ALLOW_IP6" ] && return 0
	case $1 in
	2001:db8:*) return 0 ;;
	esac
	return 1
}

# allowed_mail — the domain of the address is a documented placeholder
# domain, or a subdomain of one. The domain of the OpenSSH key types is
# exempt for a key type and for nothing else.
allowed_mail() {
	_addr=$1
	_dom=${_addr##*@}
	case $_dom in
	"$KEYTYPE_MAIL_DOMAIN")
		# a key type: the prefix, and at least one character behind it
		_local=${_addr%%@*}
		case ${_local#"$KEYTYPE_MAIL_PREFIX"} in
		'' | *[!a-z0-9-]*) return 1 ;;
		esac
		case $_local in
		"$KEYTYPE_MAIL_PREFIX"*) return 0 ;;
		esac
		return 1
		;;
	esac
	for _d in $ALLOW_MAIL_DOMAIN; do
		case $_dom in
		"$_d" | *."$_d") return 0 ;;
		esac
	done
	return 1
}

# ipv6_addrs — the IPv6 addresses of a line, one per line. The line is
# padded so that every address has a delimiter on both sides, and the
# delimiter is removed again afterwards.
ipv6_addrs() {
	printf '%s\n' "$1" | sed -e 's/^/ /' -e 's/$/ /' |
		grep -oE -e "$IPV6" 2>/dev/null |
		sed -e 's/^[^0-9A-Fa-f:]//' -e 's/[^0-9A-Fa-f:]$//' || true
}

# line_is_clean — 0 when the line holds nothing that must not be shipped
line_is_clean() {
	_l=$1
	# the shapes that have no documented exception
	printf '%s\n' "$_l" | grep -qiE -e "$KEYS|$TOKENS|$SECRETS|$TLD" && return 1
	# addresses: whole addresses only
	for _ip in $(printf '%s\n' "$_l" | tr -c '0-9.' ' ' | tr ' ' '\n' | grep -E "^$IPS\$"); do
		allowed_ip "$_ip" || return 1
	done
	# IPv6 addresses: whole addresses only
	for _ip6 in $(ipv6_addrs "$_l"); do
		allowed_ip6 "$_ip6" || return 1
	done
	# e-mail addresses: whole addresses only
	for _mail in $(printf '%s\n' "$_l" | tr -c 'A-Za-z0-9._%+@-' ' ' | tr ' ' '\n' | grep -E "^$EMAIL\$"); do
		allowed_mail "$_mail" || return 1
	done
	return 0
}

# leak_refs — the files of the tree that hold something that must not be
# shipped
leak_refs() {
	_bad=''
	_hits="$work/hits"
	_files="$work/files"
	tree_names > "$_files"
	while IFS= read -r _f; do
		[ -n "$_f" ] || continue
		[ -f "$leak_root/$_f" ] || continue
		# only the lines that hold something worth a closer look are read
		# one by one; a binary file is read as well, or a key in a blob
		# walks through the check
		grep -a -iE -e "$SHAPES" "$leak_root/$_f" > "$_hits" 2>/dev/null || true
		[ -s "$_hits" ] || continue
		while IFS= read -r _line; do
			[ -n "$_line" ] || continue
			if ! line_is_clean "$_line"; then
				_bad="$_bad $_f"
				break
			fi
		done < "$_hits"
	done < "$_files"
	printf '%s' "$_bad"
}

# The private half of the check. It is a function of this file: a site that
# wants the names of its own organisation checked copies the function into
# its own copy of the suite, or calls it from a wrapper.
#
# deny_refs — the files of the tree that hold a name from the private list.
# The list lives outside the repository: $WTFBSD_DENYLIST names a readable
# file whose non-comment lines are case-insensitive extended regular
# expressions, matched against every file of the tree. The repository
# ships no such file: the list of the names that must not be published is
# itself a publication of them.
deny_refs() {
	[ -n "${WTFBSD_DENYLIST:-}" ] || return 0
	if [ ! -r "$WTFBSD_DENYLIST" ]; then
		printf 'WTFBSD_DENYLIST is set but not readable: %s\n' "$WTFBSD_DENYLIST" >&2
		return 1
	fi
	_bad=''
	grep -v '^[[:space:]]*#' "$WTFBSD_DENYLIST" 2>/dev/null | grep -v '^[[:space:]]*$' > "$work/deny.pats" || true
	while IFS= read -r _pat; do
		[ -n "$_pat" ] || continue
		_found=$(cd "$leak_root" && tree_files | xargs -0 grep -lIiE -e "$_pat" 2>/dev/null || true)
		[ -n "$_found" ] && _bad="$_bad $_found"
	done < "$work/deny.pats"
	printf '%s' "$_bad"
}

_bad=$(leak_refs)
if [ -z "$_bad" ]; then
	ok "no_internal_refs: no key, token or unlisted address in the tree"
else
	no "no_internal_refs: found in:$_bad"
fi

# (i1) the private half of the check: the deny-list is used only when it is
#      named, and it is never part of the repository.
if [ -z "${WTFBSD_DENYLIST:-}" ]; then
	ok "no_internal_refs: no private deny-list named (the public shapes were checked)"
else
	_bad=$(deny_refs)
	_rc=$?
	if [ "$_rc" -ne 0 ]; then
		no "no_internal_refs: the private deny-list is not readable"
	elif [ -z "$_bad" ]; then
		ok "no_internal_refs: no name from the private deny-list in the tree"
	else
		no "no_internal_refs: the private deny-list was found in:$_bad"
	fi
fi

# (i2) a probe per shape: the file is written into the tree, the check must
#      catch it, and the file is removed again.
probe_refs() { # probe_refs <label> <pattern> <content>
	_pf="probe-leak-$1.txt"
	printf '%s\n' "$3" > "$repo/$_pf"
	if grep -qE -e "$2" "$repo/$_pf" 2>/dev/null && leak_refs | grep -qF "$_pf"; then
		ok "no_internal_refs: the probe for $1 is caught"
	else
		no "no_internal_refs: the probe for $1 is caught"
	fi
	rm -f "$repo/$_pf"
}
probe_refs address "$IPS" "$(_frag '127.0.0.' '150')"
probe_refs ipv6 "$IPV6" "$(_frag 'fd00:' ':1')"
probe_refs email "$EMAIL" "$(_frag 'probe-user' '@mail.example.net')"
probe_refs tld "$TLD" "$(_frag 'host' '.internal')"
probe_refs tld-home "$TLD" "$(_frag 'host' '.home.arpa')"
probe_refs private-key "$KEYS" "$(_frag 'BEG' 'IN RSA PRIVATE KEY')"
probe_refs public-key "$KEYS" "$(_frag 'ssh-' 'ed25519 AAAA')"
probe_refs token "$TOKENS" "$(_frag 'gh' 'p_')0123456789abcdefghijklmnopqrstuvwxyz"
probe_refs token-project "$TOKENS" "$(_frag 'sk-' 'proj-')AAAAAAAAAAAAAAAAAAAAAAAA"
probe_refs credential-api "$SECRETS" "$(_frag 'api' 'Key')=x"
probe_refs credential-api-underscore "$SECRETS" "$(_frag 'api' '_key')=x"
probe_refs credential-base "$SECRETS" "$(_frag 'base' 'URL')=x"
probe_refs credential-authorization "$SECRETS" "$(_frag 'Bea' 'rer abc')"

# (i2a) the OpenSSH key types are shaped like e-mail addresses: they are
#       the key type of a security key, not a leak.
_pf="probe-leak-keytype.txt"
printf '%s\n' "$(_frag 'sk-ssh-ed25519' '@openssh.com')" > "$repo/$_pf"
if leak_refs | grep -qF "$_pf"; then
	no "no_internal_refs: the OpenSSH key type is not a leak"
else
	ok "no_internal_refs: the OpenSSH key type is not a leak"
fi
rm -f "$repo/$_pf"

# (i2c) only a key type is exempt on the domain of the OpenSSH key types:
#       another address on that domain is a leak like any other.
_pf="probe-leak-keytype-other.txt"
printf '%s\n' "$(_frag 'root' '@openssh.com')" > "$repo/$_pf"
if leak_refs | grep -qF "$_pf"; then
	ok "no_internal_refs: an address that is not a key type is caught"
else
	no "no_internal_refs: an address that is not a key type is caught"
fi
rm -f "$repo/$_pf"

# (i2b) a binary file: the check has to look into it as well, or a key in
#       a binary blob walks through it.
_pf="probe-leak-binary.bin"
printf '%s\000a binary file\000\n' "$(_frag 'sk-' 'ant-')AAAAAAAAAAAAAAAAAAAAAAAA" > "$repo/$_pf"
if leak_refs | grep -qF "$_pf"; then
	ok "no_internal_refs: the probe for a binary file is caught"
else
	no "no_internal_refs: the probe for a binary file is caught"
fi
rm -f "$repo/$_pf"

# (i3) the deny-list probe: the list is a file outside the tree, the word
#      is in a file inside it.
_dl="$work/denylist.probe"
printf '%s\n' "$(_frag 'zorbl' 'axian')" > "$_dl"
_pf="probe-leak-denylist.txt"
printf '%s\n' "$(_frag 'zorbl' 'axian')" > "$repo/$_pf"
_was=${WTFBSD_DENYLIST:-}
WTFBSD_DENYLIST="$_dl"
_found=$(deny_refs)
WTFBSD_DENYLIST=$_was
if printf '%s' "$_found" | grep -qF "$_pf"; then
	ok "no_internal_refs: the deny-list probe is caught"
else
	no "no_internal_refs: the deny-list probe is caught"
fi
rm -f "$repo/$_pf"

# (i4) the round reports are per-round artifacts: they quote session
#      material, so they are never tracked.
if [ -d "$repo/.git" ]; then
	_reports=$(git -C "$repo" ls-files 2>/dev/null | grep '^ROUND-REPORT' || true)
	[ -z "$_reports" ] && ok "no round report is tracked" || no "a round report is tracked:$_reports"
	if grep -q '^ROUND-REPORT\*\.md$' "$repo/.gitignore" 2>/dev/null; then
		ok "the round reports are ignored by git"
	else
		no "the round reports are not ignored by git"
	fi
else
	ok "no round report is tracked (not a git checkout)"
fi

# (i5) the artifacts of a CI run are not part of the tree. The workspace of
#      a job holds the product configuration of the site, the file
#      parameter of the pipeline, the console logs of the VMs and the
#      scratch files of the tooling. They are ignored by git, so that the
#      leak check reads the tree of the template and not the debris of a
#      run.
#
#      The probe runs against a COPY of the tree: the artifacts are written
#      into the copy and the copy goes away with the scratch directory.
#      The product configuration of the working tree is never written to
#      and never deleted.
#
#      The probe needs the ignore rules of git, so it is skipped in a tree
#      that is not a git checkout - the same way (i4) is.
if [ -d "$repo/.git" ] && command -v git >/dev/null 2>&1; then
	_probe_tree="$work/probe-tree"
	mkdir -p "$_probe_tree"
	cp -R "$repo/." "$_probe_tree/"
	mkdir -p "$_probe_tree/console-logs"
	printf '%s\n' "$(_frag '10.42.' '0.7')" > "$_probe_tree/console-logs/boot-appliance-x.addr"
	printf 'PUBLISH_TARGET=%s\n' "$(_frag 'deploy@pkg.' 'example.net:/srv/pkg')" > "$_probe_tree/product.conf"
	_leak_root_was=$leak_root
	leak_root=$_probe_tree
	_bad=$(leak_refs)
	leak_root=$_leak_root_was
	if [ -z "$_bad" ]; then
		ok "no_internal_refs: the artifacts of a CI run are not a leak"
	else
		no "no_internal_refs: the artifacts of a CI run are not a leak (found in:$_bad)"
	fi
else
	ok "no_internal_refs: the artifacts of a CI run are not a leak (not a git checkout: the probe needs the ignore rules of git)"
fi

# (i6) the shipped serial fixtures carry no MAC address: a MAC address is
#      shaped like an IPv6 address and the leak check cannot tell the two
#      apart, so the fixture must not carry one. The documented addresses
#      of the fixtures are the documentation range of RFC 5737.
_fmac=''
for _f in "$FIXTURES"/serial-*.log; do
	[ -f "$_f" ] || continue
	if grep -a -qiE -e '[0-9a-f]{2}(:[0-9a-f]{2}){5}' "$_f"; then
		_fmac="$_fmac $(basename "$_f")"
	fi
done
if [ -z "$_fmac" ]; then
	ok "the serial fixtures carry no MAC address"
else
	no "the serial fixtures carry a MAC address:$_fmac"
fi

# (i5b) the suite must not touch the product configuration of the tree it
#       reads: it is the file the pipeline and the developer use, and a
#       developer who runs the suite must find it as it was. The suite is
#       therefore run against a copy of the tree that carries one, and the
#       file must come out byte-identical.
#
#       The run against the copy is the suite itself: it is skipped there
#       (WTFBSD_NO_SUITE_RUN), or the suite would run itself for ever.
if [ -n "${WTFBSD_NO_SUITE_RUN:-}" ]; then
	ok "the suite leaves the product configuration of the tree alone (not run: this is the suite)"
elif [ ! -f "$repo/tests/run-tests.sh" ]; then
	ok "the suite leaves the product configuration of the tree alone (not run: the suite is not in this tree)"
else
	_suite_tree="$work/suite-tree"
	mkdir -p "$_suite_tree"
	cp -R "$repo/." "$_suite_tree/"
	printf 'DISTRO_OS="freebsd"\nDISTRO_NAME="ExampleBSD"\n' > "$_suite_tree/product.conf"
	cp "$_suite_tree/product.conf" "$work/product.conf.before"
	( cd "$_suite_tree" && WTFBSD_NO_SUITE_RUN=1 sh tests/run-tests.sh ) > "$work/suite-run.log" 2>&1
	_rc=$?
	if cmp -s "$work/product.conf.before" "$_suite_tree/product.conf"; then
		ok "the suite leaves the product configuration of the tree alone"
	else
		no "the suite leaves the product configuration of the tree alone (the file changed or is gone, the suite in the copy exited $_rc)"
	fi
fi
# the artifacts of a run are ignored by git, and that is what makes the
# check above clean
if [ -d "$repo/.git" ] && command -v git >/dev/null 2>&1; then
	_ign=''
	for _p in product.conf PRODUCT_CONF console-logs/boot-appliance-x.addr .wtfbsd-vms; do
		git -C "$repo" check-ignore -q -- "$_p" 2>/dev/null || _ign="$_ign $_p"
	done
	if [ -z "$_ign" ]; then
		ok "the artifacts of a CI run are ignored by git"
	else
		no "the artifacts of a CI run are not ignored by git:$_ign"
	fi
else
	ok "the artifacts of a CI run are ignored by git (not a git checkout)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
