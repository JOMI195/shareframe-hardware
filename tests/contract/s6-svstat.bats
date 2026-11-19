# s6-svstat as the board's s6 (2.13.1.0, the version Buildroot builds) prints it; the services
# page parses these lines. Pids and seconds are normalized, the layout is s6's own.
load ../support/common

setup() {
	sf_setup
	D="$T/svc"
	mkdir -p "$D/up" "$D/crash"
	printf '#!/bin/sh\nexec sleep 1000\n' > "$D/up/run"
	printf '#!/bin/sh\nexit 3\n' > "$D/crash/run"
	chmod +x "$D/up/run" "$D/crash/run"
	(cd "$D/up" && exec s6-supervise .) 3>&- &
	(cd "$D/crash" && exec s6-supervise .) 3>&- &
}

teardown() { s6-svc -dx "$D/up" "$D/crash" 2>/dev/null || true; }

normalized() { s6-svstat "$D/$1" | sed -E 's/pid [0-9]+/pid 1234/; s/pgid [0-9]+/pgid 1234/; s/[0-9]+ seconds/56 seconds/g'; }
state_is() { s6-svstat "$D/$1" 2>/dev/null | grep -q "^$2"; }

# bats test_tags=contract
@test "golden svstat-*.txt: up, crash-looping, stopped" {
	eventually 5 state_is up 'up (pid'
	eventually 5 state_is crash 'down (exitcode 3)'
	normalized up > "$T/svstat-up.txt"
	normalized crash > "$T/svstat-down-exitcode.txt"
	s6-svc -d "$D/up"
	eventually 5 state_is up 'down (signal'
	normalized up > "$T/svstat-down-signal.txt"
	for f in svstat-up.txt svstat-down-signal.txt svstat-down-exitcode.txt; do assert_golden "$f" "$T/$f"; done
}
