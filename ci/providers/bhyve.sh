#!/bin/sh
#
# ci/providers/bhyve.sh — the reference VM provider: stock FreeBSD bhyve(8).
#
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# This is the provider the repository ships as an example. A site with its
# own hypervisor writes its own provider script and points
# $WTFBSD_VM_PROVIDER_PATH at it; the subcommands and their meaning are the
# same (see README.md, "VM provider contract").
#
#   create NAME IMAGE   start a VM on the disk image
#   console NAME        print the path of the captured serial console log
#   addr NAME           print the address of the VM
#   destroy NAME        stop and destroy the VM
#
# Environment:
#   WTFBSD_TAP          tap device for the guest NIC        (default: tap0)
#   WTFBSD_BRIDGE       bridge the tap is attached to       (default: bridge0)
#   WTFBSD_CONSOLE_DIR  where the console logs are written  (default: $PWD/console-logs)
#   WTFBSD_VM_CPUS      number of virtual CPUs              (default: 2)
#   WTFBSD_VM_MEMORY    guest memory                        (default: 2G)
#   WTFBSD_VM_FIRMWARE  UEFI firmware                       (default:
#                       /usr/local/share/uefi-firmware/BHYVE_UEFI.fd)
#   WTFBSD_NMDM_INDEX   null-modem pair index               (default: 0)
#   WTFBSD_VM_ADDR      the address of the guest, when it is not discovered
#   WTFBSD_VM_DEVICE_DIR where the hypervisor keeps its VM devices
#                       (default: /dev/vmm)
#
# The tap and the bridge names must match ^[a-z][a-z0-9]*[0-9]+$ and the VM
# name must match ^[a-z][a-z0-9-]{0,30}$: both end up on a command line.
#
# The serial console is a null-modem pair (nmdm(4)): the guest side is the A
# end, the host reads the B end. The B end is copied into a log file under
# the job workspace so that the boot test can watch it.

set -eu

PROG=$(basename -- "$0")

die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }
fail() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 3; }
# log — the progress of a subcommand. It goes to stderr: stdout carries the
# machine-readable answer of console and addr, and nothing else.
log() { printf '%s\n' "$*" >&2; }

# show — print a value with the characters that would break a log line
show() { printf '%s' "$1" | tr -c '[:print:]' '?'; }

# Two jobs on one host must not fight over the same null-modem pair or the
# same tap: the executor number the agent reports gives every job its own.
# The null-modem module takes any unit number, so the executor number is
# used as it is.
exec_no=${EXECUTOR_NUMBER:-}
if [ -n "$exec_no" ]; then
	case $exec_no in
	'' | *[!0-9]*) die "EXECUTOR_NUMBER must be a number: $exec_no" ;;
	esac
	: "${WTFBSD_NMDM_INDEX:=$exec_no}"
	: "${WTFBSD_TAP:=tap${exec_no}}"
fi

TAP=${WTFBSD_TAP:-tap0}
BRIDGE=${WTFBSD_BRIDGE:-bridge0}
CONSOLE_DIR=${WTFBSD_CONSOLE_DIR:-${PWD}/console-logs}
CPUS=${WTFBSD_VM_CPUS:-2}
MEMORY=${WTFBSD_VM_MEMORY:-2G}
FIRMWARE=${WTFBSD_VM_FIRMWARE:-/usr/local/share/uefi-firmware/BHYVE_UEFI.fd}
NMDM=${WTFBSD_NMDM_INDEX:-0}
DEVICE_DIR=${WTFBSD_VM_DEVICE_DIR:-/dev/vmm}

NAME_RE='^[a-z][a-z0-9-]{0,30}$'
NET_RE='^[a-z][a-z0-9]*[0-9]+$'

# check_name — the name rules, checked with case patterns and a length
# check: a line-based match would accept the first line of a name that
# carries a newline in it.
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

# check_net — the device name rules: a letter, then letters and digits, and
# a digit at the end.
check_net() {
	_v=$2
	case $_v in
	'' | *[!a-z0-9]*) die "$1 must match $NET_RE: $(show "$_v")" ;;
	esac
	case $_v in
	[a-z]*) : ;;
	*) die "$1 must match $NET_RE: $(show "$_v")" ;;
	esac
	case $_v in
	*[0-9]) : ;;
	*) die "$1 must match $NET_RE: $(show "$_v")" ;;
	esac
}

# require_root — bhyve(8) and nmdm(4) need root, and this provider runs
# with the privileges of the agent.
require_root() {
	[ "$(id -u)" -eq 0 ] ||
		fail 'this provider must run as root (bhyve(8) and nmdm(4) need it)'
}

# stop_reader — stop the console reader of an earlier run of this VM, if it
# is still around. The reader holds the null-modem end open, so a stale one
# keeps the guest from writing anything.
#
# The pid is read from a file in the workspace of the job, so its content is
# not under the control of the provider. A value that is not the pid of a
# reader is refused and never signalled: kill(2) with 0 reaches every
# process of the group of the caller, and with 1 the init process.
stop_reader() {
	_pidfile="$CONSOLE_DIR/$1.reader.pid"
	[ -f "$_pidfile" ] || return 0
	_pid=$(cat "$_pidfile" 2>/dev/null || printf '')
	rm -f "$_pidfile"
	case $_pid in
	'' | *[!0-9]*) return 0 ;;
	esac
	# a pid that is not a number of a process of this host is refused: the
	# longest pid that can exist is far below this
	[ "${#_pid}" -le 9 ] || return 0
	[ "$_pid" -gt 1 ] || return 0
	if kill "$_pid" 2>/dev/null; then
		# the reader holds the null-modem end open until it is gone: wait
		# for it (at most 5 s), so that the next reader opens a free end
		_w=0
		while kill -0 "$_pid" 2>/dev/null && [ "$_w" -lt 50 ]; do
			sleep 0.1
			_w=$((_w + 1))
		done
		log "bhyve: stopped the console reader of $1"
	fi
	return 0
}

usage() {
	printf 'usage: %s create NAME IMAGE\n' "$PROG" >&2
	printf '       %s console NAME\n' "$PROG" >&2
	printf '       %s addr NAME\n' "$PROG" >&2
	printf '       %s destroy NAME\n' "$PROG" >&2
	exit 1
}

[ $# -ge 1 ] || usage
cmd=$1
shift

case $cmd in
create)
	[ $# -eq 2 ] || usage
	name=$1
	image=$2
	check_name "$name"
	check_net WTFBSD_TAP "$TAP"
	check_net WTFBSD_BRIDGE "$BRIDGE"
	[ -f "$image" ] || die "image not found, or not a regular file: $image"
	case $image in
	*,*) die "the image path must not contain a comma (bhyve(8) splits its device options on commas): $image" ;;
	esac
	# the console reader of an earlier run holds the null-modem end open: it
	# has to go before a new one starts
	stop_reader "$name"
	log "bhyve: $name uses tap $TAP and /dev/nmdm${NMDM}B"
	require_root
	command -v bhyve >/dev/null 2>&1 || fail 'bhyve(8) is not installed (it is in the base system)'
	command -v bhyvectl >/dev/null 2>&1 || fail 'bhyvectl(8) is not installed (it is in the base system)'
	mkdir -p "$CONSOLE_DIR"
	# The tap of the guest NIC. Opening a tap device creates it outside any
	# bridge and down, so the provider makes the tap here: what the host
	# has to have is the bridge, not the tap. What the provider did with
	# the tap is written down, so that the destroy only takes away the tap
	# that the provider made. The names of the tap and of the bridge are
	# written down with it: the destroy acts on these names and not on the
	# ones the environment happens to hold at that time.
	if ifconfig "$TAP" >/dev/null 2>&1; then
		_created=no
	else
		ifconfig "$TAP" create || fail "could not create the tap $TAP"
		_created=yes
	fi
	# a create that fails after this point destroys the tap it made, so
	# that a failed create leaves nothing behind on the host
	undo_tap() {
		# under set -e every step tolerates a failure, so that the cleanup
		# always completes and the caller reaches its own fail
		ifconfig "$BRIDGE" deletem "$TAP" 2>/dev/null || true
		if [ "$_created" = yes ]; then
			ifconfig "$TAP" destroy 2>/dev/null || true
		fi
		rm -f "$CONSOLE_DIR/$name.tap"
	}
	{
		printf 'tap=%s\n' "$TAP"
		printf 'bridge=%s\n' "$BRIDGE"
		printf 'created=%s\n' "$_created"
	} > "$CONSOLE_DIR/$name.tap"
	ifconfig "$TAP" up || { undo_tap; fail "could not bring the tap $TAP up"; }
	# the tap is a member of the bridge: ifconfig(8) has no "master"
	# keyword, a member is added with "addm" and removed with "deletem".
	# A run that died hard leaves the tap in the bridge, and an addm of a
	# member that is already there fails with EEXIST: the member list of
	# the bridge is read first, and the addm is skipped when the tap is
	# already one of them. A bridge that cannot be listed is left to the
	# addm, which fails loudly when the tap is not a member.
	if ifconfig "$BRIDGE" 2>/dev/null | grep -q "member: $TAP "; then
		log "bhyve: $TAP is already a member of $BRIDGE"
	else
		ifconfig "$BRIDGE" addm "$TAP" || { undo_tap; fail "could not attach $TAP to $BRIDGE (is the bridge there?)"; }
	fi
	logfile="$CONSOLE_DIR/$name.log"
	: > "$logfile"
	if [ -n "${WTFBSD_VM_ADDR:-}" ]; then
		printf '%s\n' "$WTFBSD_VM_ADDR" > "$CONSOLE_DIR/$name.addr"
	fi
	kldload nmdm 2>/dev/null || true
	# The guest writes to the A end of the pair, the host reads the B end.
	# A null-modem end opens in canonical mode with ECHO, and getty's
	# "login: " prompt carries no newline: a canonical read never returns it
	# and the echo feeds the guest its own output back as input. The reader
	# therefore puts the device into raw mode without echo, and reads it
	# through the very same open file.
	( stty raw -echo; exec cat ) < "/dev/nmdm${NMDM}B" > "$logfile" &
	reader=$!
	printf '%s\n' "$reader" > "$CONSOLE_DIR/$name.reader.pid"
	# The reader blocks in the open of the B end until the guest opens the
	# A end, so it is not possible to tell from its state whether it can
	# read. The check that follows the start of bhyve is the one that says
	# something.
	bhyve -c "$CPUS" -m "$MEMORY" -H -A -P \
		-s 0,hostbridge \
		-s 2,virtio-blk,"$image" \
		-s 3,virtio-net,"$TAP" \
		-s 31,lpc \
		-l com1,"/dev/nmdm${NMDM}A" \
		-l bootrom,"$FIRMWARE" \
		"$name" > "$CONSOLE_DIR/$name.bhyve.log" 2>&1 &
	vm=$!
	printf '%s\n' "$vm" > "$CONSOLE_DIR/$name.pid"
	sleep 1
	kill -0 "$vm" 2>/dev/null || { stop_reader "$name"; undo_tap; fail "bhyve exited at once (see $CONSOLE_DIR/$name.bhyve.log)"; }
	log "bhyve: started $name (console log $logfile)"
	;;
console)
	[ $# -eq 1 ] || usage
	name=$1
	check_name "$name"
	file="$CONSOLE_DIR/$name.log"
	[ -f "$file" ] || fail "no console log for $name ($file)"
	printf '%s\n' "$file"
	;;
addr)
	[ $# -eq 1 ] || usage
	name=$1
	check_name "$name"
	if [ -n "${WTFBSD_VM_ADDR:-}" ]; then
		printf '%s\n' "$WTFBSD_VM_ADDR"
	elif [ -f "$CONSOLE_DIR/$name.addr" ]; then
		cat "$CONSOLE_DIR/$name.addr"
	else
		fail "no address known for $name: set WTFBSD_VM_ADDR (this provider does not do DHCP)"
	fi
	;;
destroy)
	[ $# -eq 1 ] || usage
	name=$1
	check_name "$name"
	command -v bhyvectl >/dev/null 2>&1 ||
		fail 'bhyvectl(8) is not installed (it is in the base system)'
	# The VM is stopped first. The NIC of a running guest is not taken
	# away from under it, and a destroy that fails leaves the VM and its
	# tap alone instead of reporting a failed run for a guest that is
	# still up.
	if [ -e "$DEVICE_DIR/$name" ]; then
		require_root
		_gone=0
		out=$(bhyvectl --destroy --vm="$name" 2>&1) || {
			printf '%s\n' "$out" >&2
			case $out in
			*'could not be opened'*)
				# bhyvectl(8) could not open the VM: it is gone already
				_gone=1
				;;
			*) fail "bhyvectl --destroy --vm=$name failed" ;;
			esac
		}
		if [ "$_gone" -eq 0 ]; then
			log "bhyve: destroyed $name"
		else
			log "bhyve: $name is not running (already gone)"
		fi
	else
		log "bhyve: $name is not running (already gone)"
	fi
	# then the reader of the console goes, and then the tap leaves the
	# bridge again
	stop_reader "$name"
	rm -f "$CONSOLE_DIR/$name.pid"
	# The tap leaves the bridge again, and a tap that this provider made is
	# destroyed with it: a tap that was already there belongs to the host.
	# The names of the tap and of the bridge are the ones of the create:
	# the environment of the destroy may hold other ones (the executor
	# number of the job is not set in every context), and the tap of the
	# host must not be taken away with the tap of the guest.
	_tapstate="$CONSOLE_DIR/$name.tap"
	if [ -f "$_tapstate" ]; then
		_tap=''
		_bridge=''
		_created=no
		while IFS='=' read -r _key _value; do
			case $_key in
			tap) _tap=$_value ;;
			bridge) _bridge=$_value ;;
			created) _created=$_value ;;
			esac
		done < "$_tapstate"
		if [ -z "$_tap" ] || [ -z "$_bridge" ]; then
			# the state file names no tap: the provider cannot tell
			# which tap it is, and the tap is left alone
			log "bhyve: the tap state of $name names no tap: the tap is left alone"
		else
			ifconfig "$_bridge" deletem "$_tap" 2>/dev/null || true
			if [ "$_created" = yes ]; then
				ifconfig "$_tap" destroy 2>/dev/null || true
			fi
		fi
		rm -f "$_tapstate"
	fi
	;;
*)
	usage
	;;
esac
