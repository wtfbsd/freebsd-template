#!/bin/sh
#
# tests/boot-test.sh IMAGE PROFILE [NAME] — boot a built image and wait until
# it is usable.
#
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# Usage: tests/boot-test.sh IMAGE PROFILE [NAME]
#        (PROFILE: desktop | appliance)
#
# NAME is the name of the VM. The caller may want to know it — the pipeline
# destroys the VMs it created by name — so it can be given as the third
# argument or in WTFBSD_VM_NAME. Without one, the name is derived from the
# profile and the process id.
#
# The VM is created and destroyed through ci/vm.sh only: this script never
# talks to a hypervisor itself, so it works with any provider.
#
# The test waits for a login prompt on the serial console. For the appliance
# profile it also waits for sshd to answer on the SSH port. For the desktop
# profile the serial login prompt is enough for now: the desktop greeter is
# not visible on a serial console.
#
# Environment:
#   BOOT_TIMEOUT    seconds to wait for the login prompt (default: 600)
#   SSH_PORT        port the appliance profile must answer on (default: 22)
#   WTFBSD_VM_NAME  name of the VM, when it is not given as an argument
#
# The VM is always destroyed, also when the wait times out or the script is
# interrupted.

set -eu

PROG=$(basename -- "$0")
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH='' cd -- "$here/.." && pwd)
VM="$repo/ci/vm.sh"

die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }
log() { printf '%s\n' "$*"; }

# check_name — the name rules of the providers: letters, digits and dashes,
# starting with a letter, at most 31 characters.
check_name() {
	_v=$1
	case $_v in
	'' | *[!a-z0-9-]*) die "VM name must be letters, digits and dashes: $_v" ;;
	esac
	case $_v in
	[a-z]*) : ;;
	*) die "VM name must start with a letter: $_v" ;;
	esac
	[ "${#_v}" -le 31 ] || die "VM name must be at most 31 characters: $_v"
}

[ $# -ge 2 ] && [ $# -le 3 ] || {
	printf 'usage: %s IMAGE PROFILE [NAME]\n' "$PROG" >&2
	exit 1
}
image=$1
profile=$2

case $profile in
desktop | appliance) ;;
*) die "PROFILE must be desktop or appliance: $profile" ;;
esac
[ -f "$image" ] || die "image not found: $image"

timeout=${BOOT_TIMEOUT:-600}
case $timeout in
'' | *[!0-9]*) die "BOOT_TIMEOUT must be a number of seconds: $timeout" ;;
esac

name=${3:-${WTFBSD_VM_NAME:-boot-$profile-$$}}
check_name "$name"

# A destroy that fails is a VM that is still running. The flag is set by
# the trap, and the trap turns it into a non-zero exit: a leaked VM must
# not be reported as a clean run.
destroy_failed=0
destroy() {
	if ! sh "$VM" destroy "$name" >/dev/null; then
		printf '%s: destroy failed: VM %s may still be running\n' "$PROG" "$name" >&2
		destroy_failed=1
	fi
}
trap 'destroy; if [ "$destroy_failed" -ne 0 ]; then exit 1; fi' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

log "boot test: $image ($profile) as $name"
sh "$VM" create "$name" "$image"

console=$(sh "$VM" console "$name")
[ -f "$console" ] || die "the console log path is not a file: $console"

deadline=$(($(date +%s) + timeout))
while :; do
	if grep -q 'login:' "$console" 2>/dev/null; then
		break
	fi
	[ "$(date +%s)" -lt "$deadline" ] ||
		die "timed out after ${timeout}s waiting for a login prompt on the serial console; the serial console log is $console"
	sleep 2
done
log "boot test: login prompt seen on the serial console"

if [ "$profile" = appliance ]; then
	# The address of the VM has to be an address: a host name, an IPv4
	# address, or an IPv6 address in its bracketed form. The brackets of
	# the IPv6 form are stripped first, because the set of the allowed
	# characters holds no bracket.
	if ! addr=$(sh "$VM" addr "$name"); then
		die "the provider returned no address for $name"
	fi
	case $addr in
	\[*\]) addr=${addr#\[}; addr=${addr%\]} ;;
	esac
	case $addr in
	'' | -* | *[!A-Za-z0-9._:%-]*) die "the provider returned something that is not an address: $addr" ;;
	esac
	port=${SSH_PORT:-22}
	deadline=$(($(date +%s) + timeout))
	while :; do
		if nc -z -w 2 "$addr" "$port" >/dev/null 2>&1; then
			break
		fi
		[ "$(date +%s)" -lt "$deadline" ] ||
			die "timed out after ${timeout}s waiting for sshd on $addr:$port"
		sleep 2
	done
	log "boot test: sshd answered on $addr:$port"
fi

# The VM is destroyed before the verdict is printed: a destroy that failed
# means the VM may still be running, and the run failed with it.
destroy
trap - EXIT HUP INT TERM
if [ "$destroy_failed" -ne 0 ]; then
	printf '%s: boot test: FAIL\n' "$PROG" >&2
	exit 1
fi

log "boot test: PASS"
