# Loaded by every .bats file: bats libraries, repo paths, PATH stubs. NO TESTS LIVE HERE.
bats_load_library bats-support
bats_load_library bats-assert
bats_load_library bats-file

SRC="${SRC:-/src}"
OVERLAY="$SRC/br2-external/overlay"
BIN="$OVERLAY/usr/bin"
S6="$OVERLAY/usr/libexec/s6"
PKG="$SRC/br2-external/package"

# A fresh temp dir and PATH per test: stubs first, then the image's own tools, then busybox.
sf_setup() {
	T="$BATS_TEST_TMPDIR"
	STUBS="$T/stubs"
	export CALLS="$T/calls"
	mkdir -p "$STUBS"
	export PATH="$STUBS:$BIN:/opt/busybox/bin:/usr/bin:/bin"
	export SF_LIB="$OVERLAY/usr/lib/shareframe/lib.sh"
}

# Build and release tooling runs on the developer's host: GNU userland, no busybox.
host_setup() {
	sf_setup
	export PATH="$STUBS:/usr/bin:/bin:/usr/sbin:/sbin"
}

# stub <name> [body]: a command on PATH that records "<name> <args>" in $CALLS, then runs body.
stub() {
	{
		printf '#!/bin/sh\necho "%s $*" >> "$CALLS"\n' "$1"
		[ $# -lt 2 ] || printf '%s\n' "$2"
	} > "$STUBS/$1"
	chmod +x "$STUBS/$1"
}

# quiet_stub <name> <body>: a command on PATH that only runs body.
quiet_stub() {
	printf '#!/bin/sh\n%s\n' "$2" > "$STUBS/$1"
	chmod +x "$STUBS/$1"
}

# sync_records <file>: a `sync` on PATH that appends what <file> holds at that moment to $T/synced.
sync_records() { quiet_stub sync "cat '$1' >> '$T/synced' 2>/dev/null || echo none >> '$T/synced'"; }
synced() { grep -qx -- "$1" "$T/synced" 2>/dev/null || fail "'$1' never reached the card; synced: $(cat "$T/synced" 2>/dev/null)"; }

called() { grep -qs -- "^$1" "$CALLS"; }
assert_called() { called "$1" || fail "no call starting with '$1'; calls: $(cat "$CALLS" 2>/dev/null)"; }
refute_called() { ! called "$1" || fail "unexpected call starting with '$1'"; }

# eventually <seconds> <command...>: retries until the command succeeds.
eventually() {
	local tries=$(($1 * 10))
	shift
	while ! "$@" 2>/dev/null; do
		tries=$((tries - 1))
		[ "$tries" -gt 0 ] || { "$@"; return; }
		sleep 0.1
	done
}

# assert_golden <name> <file>: the file must equal tests/contract/golden/<name>, which
# shareframe-board's contract tests parse. UPDATE_GOLDEN=1 (./test.sh contract
# --update-golden) rewrites the golden instead.
assert_golden() {
	if [ "${UPDATE_GOLDEN:-0}" = 1 ]; then
		cp "$2" "/golden/$1"
		return
	fi
	[ -f "$SRC/tests/contract/golden/$1" ] || fail "no golden $1; run ./test.sh contract --update-golden"
	diff -u "$SRC/tests/contract/golden/$1" "$2" || fail "$1 differs from its golden (the board parses it)"
}

# A clock that stands still, so produced files are byte-for-byte reproducible.
fixed_clock() { quiet_stub date 'exec /usr/bin/date -d @1767323045 "$@"'; }
