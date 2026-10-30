#!/bin/sh
#
# tests/fixtures/fake-provider.sh — a VM provider for the test suite.
#
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# It implements the same contract as ci/providers/bhyve.sh, but it starts
# nothing: it records every call in a log file and serves a canned serial
# console log, so that tests/boot-test.sh can be exercised on any host.
#
# Environment:
#   WTFBSD_FAKE_CALL_LOG     file the calls are appended to
#   WTFBSD_FAKE_CONSOLE_LOG  the canned serial log that is served
#   WTFBSD_FAKE_CONSOLE_DIR  directory the console logs are written to
#   WTFBSD_FAKE_ADDR         the address the addr subcommand prints
#
# Every call is appended to the call log as "<subcommand> <arguments>", so a
# test can assert that the VM was created and destroyed.

set -eu

PROG=$(basename -- "$0")

die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }
# log — the progress of a subcommand. It goes to stderr: stdout carries the
# machine-readable answer of console and addr, and nothing else.
log() { printf '%s\n' "$*" >&2; }

# show — print a value with the characters that would break a log line
show() { printf '%s' "$1" | tr -c '[:print:]' '?'; }

CALL_LOG=${WTFBSD_FAKE_CALL_LOG:-}
CONSOLE_LOG=${WTFBSD_FAKE_CONSOLE_LOG:-}
CONSOLE_DIR=${WTFBSD_FAKE_CONSOLE_DIR:-}
ADDR=${WTFBSD_FAKE_ADDR:-127.0.0.1}

NAME_RE='^[a-z][a-z0-9-]{0,30}$'

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

record() {
	if [ -n "$CALL_LOG" ]; then
		printf '%s\n' "$*" >> "$CALL_LOG"
	fi
}

[ $# -ge 1 ] || die 'usage: fake-provider.sh {create|console|addr|destroy} ...'
cmd=$1
shift

case $cmd in
create)
	[ $# -eq 2 ] || die 'usage: fake-provider.sh create NAME IMAGE'
	name=$1
	image=$2
	check_name "$name"
	[ -f "$image" ] || die "image not found: $image"
	[ -n "$CONSOLE_LOG" ] || die 'WTFBSD_FAKE_CONSOLE_LOG is not set'
	[ -n "$CONSOLE_DIR" ] || die 'WTFBSD_FAKE_CONSOLE_DIR is not set'
	record "create $name $image"
	mkdir -p "$CONSOLE_DIR"
	cp "$CONSOLE_LOG" "$CONSOLE_DIR/$name.log"
	printf '%s\n' "$CONSOLE_DIR/$name.log" > "$CONSOLE_DIR/$name.path"
	log "fake provider: created $name (console log $CONSOLE_DIR/$name.log)"
	;;
console)
	[ $# -eq 1 ] || die 'usage: fake-provider.sh console NAME'
	name=$1
	check_name "$name"
	record "console $name"
	[ -f "$CONSOLE_DIR/$name.path" ] || die "no console log for $name"
	cat "$CONSOLE_DIR/$name.path"
	;;
addr)
	[ $# -eq 1 ] || die 'usage: fake-provider.sh addr NAME'
	name=$1
	check_name "$name"
	record "addr $name"
	printf '%s\n' "$ADDR"
	;;
destroy)
	[ $# -eq 1 ] || die 'usage: fake-provider.sh destroy NAME'
	name=$1
	check_name "$name"
	record "destroy $name"
	log "fake provider: destroyed $name"
	;;
*)
	die "unknown subcommand: $cmd"
	;;
esac
