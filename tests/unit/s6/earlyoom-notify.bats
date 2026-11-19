# earlyoom's kill hook: event, OOM counter, error LED.
load ../../support/common

setup() {
	sf_setup
	export STATE_DIR="$T"
	stub shareframe-event
	stub shareframe-led
}

@test "every kill is logged, counted and lights the error LED" {
	EARLYOOM_PID=42 EARLYOOM_NAME=shareframe-display EARLYOOM_UID=0 "$S6/earlyoom-notify"
	"$S6/earlyoom-notify"
	assert_called 'shareframe-event oom earlyoom killed pid=42 name=shareframe-display uid=0'
	assert_equal "$(cat "$T/oom-kills")" 2
	assert_called 'shareframe-led error'
}
