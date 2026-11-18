# No RTC: the clock restored from the last save (or the build stamp), saved hourly and on stop.
load ../../support/common

setup() {
	sf_setup
	export CLOCK_FILE="$T/fake-hwclock" CLOCK_DEFAULT="$T/default"
	echo 1700000000 > "$CLOCK_DEFAULT"
	stub date 'case "$1" in +%s) echo 1767323045 ;; esac'
}

@test "restore sets the saved time, else the build stamp" {
	"$S6/fake-hwclock-restore"
	assert_called 'date -s @1700000000'
	echo 1767000000 > "$CLOCK_FILE"
	"$S6/fake-hwclock-restore"
	assert_called 'date -s @1767000000'
}

@test "a garbled save is ignored" {
	echo 'yesterday' > "$CLOCK_FILE"
	rm "$CLOCK_DEFAULT"
	"$S6/fake-hwclock-restore"
	refute_called 'date -s'
}

@test "save writes the time at start and again on stop" {
	"$S6/fake-hwclock-save" 3>&- &
	eventually 3 test -f "$CLOCK_FILE"
	rm "$CLOCK_FILE"
	kill -TERM $!
	wait $! || true
	assert_equal "$(cat "$CLOCK_FILE")" 1767323045
}
