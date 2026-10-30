#!/bin/sh
#
# ci/vm.sh — the one VM entry point used by CI and by the boot test.
#
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# Usage:
#   ci/vm.sh create NAME IMAGE   create a VM from a disk image
#   ci/vm.sh console NAME        print the path of the captured serial console log
#   ci/vm.sh addr NAME           print the address of the VM
#   ci/vm.sh destroy NAME        destroy the VM
#
# The provider is chosen with $WTFBSD_VM_PROVIDER, which names a script in
# ci/providers/<name>.sh, or with $WTFBSD_VM_PROVIDER_PATH, which points at a
# provider script that lives outside this repository (a site with its own
# hypervisor ships its own provider that way).
#
# An unknown or missing provider fails closed: this script refuses to start
# anything and exits 2.
#
# Exit codes:
#   0  success
#   1  usage error, or an argument that does not match the name rules
#   2  unknown or missing provider (nothing was started)
#   3  the provider failed (the provider's own status is passed through)
#
# VM names must match ^[a-z][a-z0-9-]{0,30}$: the name is used in file names,
# in device names and on a command line, so it stays boring on purpose.

set -eu

PROG=$(basename -- "$0")
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

NAME_RE='^[a-z][a-z0-9-]{0,30}$'
PROVIDER_RE='^[a-z][a-z0-9-]{0,30}$'

die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }
die_provider() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 2; }

# show — print a value with the characters that would break a log line
show() { printf '%s' "$1" | tr -c '[:print:]' '?'; }

usage() {
	printf 'usage: %s create NAME IMAGE\n' "$PROG" >&2
	printf '       %s console NAME\n' "$PROG" >&2
	printf '       %s addr NAME\n' "$PROG" >&2
	printf '       %s destroy NAME\n' "$PROG" >&2
	exit 1
}

# check_name — the name rules: a letter, then letters, digits and dashes, at
# most 31 characters. The rules are checked with case patterns and a length
# check rather than with a line-based match, because a line-based match
# accepts the first line of a name that carries a newline in it.
check_name() {
	_v=$1
	case $_v in
	'' | *[!a-z0-9-]*) die "VM name must match $NAME_RE: $(show "$_v")" ;;
	esac
	case $_v in
	[a-z]*) : ;;
	*) die "VM name must match $NAME_RE: $(show "$_v")" ;;
	esac
	[ "${#_v}" -le 31 ] || die "VM name must match $NAME_RE: $(show "$_v")"
}

# provider_path — print the provider script to run, or fail closed.
provider_path() {
	if [ -n "${WTFBSD_VM_PROVIDER_PATH:-}" ]; then
		[ -f "$WTFBSD_VM_PROVIDER_PATH" ] ||
			die_provider "WTFBSD_VM_PROVIDER_PATH is not a file: $WTFBSD_VM_PROVIDER_PATH"
		[ -x "$WTFBSD_VM_PROVIDER_PATH" ] ||
			die_provider "WTFBSD_VM_PROVIDER_PATH is not executable: $WTFBSD_VM_PROVIDER_PATH"
		printf '%s\n' "$WTFBSD_VM_PROVIDER_PATH"
		return 0
	fi
	provider=${WTFBSD_VM_PROVIDER:-}
	[ -n "$provider" ] ||
		die_provider 'no VM provider: set WTFBSD_VM_PROVIDER or WTFBSD_VM_PROVIDER_PATH'
	case $provider in
	'' | *[!a-z0-9-]*) die_provider "WTFBSD_VM_PROVIDER must match $PROVIDER_RE: $provider" ;;
	esac
	case $provider in
	[a-z]*) : ;;
	*) die_provider "WTFBSD_VM_PROVIDER must match $PROVIDER_RE: $provider" ;;
	esac
	[ "${#provider}" -le 31 ] ||
		die_provider "WTFBSD_VM_PROVIDER must match $PROVIDER_RE: $provider"
	file="$here/providers/$provider.sh"
	[ -f "$file" ] || die_provider "unknown VM provider: $provider (no $file)"
	[ -x "$file" ] || die_provider "VM provider is not executable: $file"
	printf '%s\n' "$file"
}

[ $# -ge 1 ] || usage
cmd=$1
shift

case $cmd in
create)
	[ $# -eq 2 ] || usage
	name=$1
	check_name "$name"
	;;
console | addr | destroy)
	[ $# -eq 1 ] || usage
	name=$1
	check_name "$name"
	;;
*)
	usage
	;;
esac

provider=$(provider_path)
exec "$provider" "$cmd" "$@"
