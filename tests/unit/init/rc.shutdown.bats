# First step of every shutdown: LED off, self-healing told to stand down, then the tree goes down.
load ../../support/common

setup() {
	sf_setup
	RC="$PKG/shareframe-init/skel/rc.shutdown"
	export LED_CMD="$STUBS/shareframe-led" SHUTTING_DOWN="$T/shutting-down"
	stub shareframe-led
	stub s6-rc "[ -f '$SHUTTING_DOWN' ] && echo 'helpers stood down' >> '$CALLS'"
}

@test "the LED goes off and helpers stand down before s6-rc takes the tree down" {
	"$RC"
	assert_equal "$(cat "$CALLS")" "shareframe-led off
s6-rc -bda change
helpers stood down"
}

@test "a failing LED does not stop the shutdown" {
	stub shareframe-led 'exit 1'
	run "$RC"
	assert_called 's6-rc -bda change'
}

@test "the image has one rc.shutdown: no overlay copy shadows the package's" {
	run find "$OVERLAY" -name 'rc.shutdown*'
	assert_output ''
}
