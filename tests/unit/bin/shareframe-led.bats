# The single LED writer: which of several claims (off > updating > protected > error > link) shows.
load ../../support/common

setup() {
	sf_setup
	export LED="$T/led" SAFE_MODE="$T/run/safe-mode" LED_RUN="$T/run/led"
	# A kernel without the pattern trigger: every state is a trigger plus two delays.
	mkdir -p "$T/led" "$T/run"
	echo 1 > "$T/led/max_brightness"
	echo "none [timer]" > "$T/led/trigger"
}

led() { shareframe-led "$1" 2>/dev/null || true; }

shown() {
	case "$(cat "$T/led/trigger")" in
		heartbeat) echo booting ;;
		none) [ "$(cat "$T/led/brightness")" = 0 ] && echo off || echo error ;;
		timer)
			case "$(cat "$T/led/delay_on")/$(cat "$T/led/delay_off")" in
				200/9800) echo normal ;;
				200/200) echo wifi-connecting ;;
				500/2000) echo wifi-down ;;
				800/800) echo ap-mode ;;
				50/50) echo updating ;;
				1000/1000) echo protected ;;
				*) echo "unknown timer" ;;
			esac ;;
		*) echo untouched ;;
	esac
}

@test "booting shows, and Wi-Fi codes replace each other" {
	led booting
	assert_equal "$(shown)" booting
	led wifi-connecting
	led normal
	assert_equal "$(shown)" normal
}

@test "an unchanged code is not written again" {
	led normal
	echo sentinel > "$T/led/delay_on"
	led normal
	assert_equal "$(cat "$T/led/delay_on")" sentinel
}

@test "an error shows over Wi-Fi codes and stays through later Wi-Fi changes" {
	led normal
	led error
	assert_equal "$(shown)" error
	led wifi-connecting
	led normal
	assert_equal "$(shown)" error
}

@test "safe mode hides Wi-Fi changes until it is lifted" {
	led ap-mode
	: > "$SAFE_MODE"
	led protected
	assert_equal "$(shown)" protected
	led wifi-connecting
	assert_equal "$(shown)" protected
	rm -f "$SAFE_MODE"
	led refresh
	assert_equal "$(shown)" wifi-connecting
}

@test "safe mode shows over an error, an update over safe mode" {
	led normal
	led error
	: > "$SAFE_MODE"
	led protected
	assert_equal "$(shown)" protected
	led updating
	assert_equal "$(shown)" updating
	led update-failed
	assert_equal "$(shown)" protected
}

@test "in safe mode a link code is ignored and off still applies" {
	: > "$SAFE_MODE"
	led protected
	led normal
	assert_equal "$(shown)" protected
	led off
	assert_equal "$(shown)" off
}

@test "an update shows over a Wi-Fi code and hands back when it ends" {
	led ap-mode
	led updating
	assert_equal "$(shown)" updating
	led update-done
	assert_equal "$(shown)" ap-mode
	led updating
	led update-failed
	assert_equal "$(shown)" error
}

@test "off shows over everything until the reboot" {
	led normal
	led error
	led updating
	led off
	assert_equal "$(shown)" off
	led normal
	led refresh
	assert_equal "$(shown)" off
}

@test "an unknown state is refused and leaves the LED alone" {
	led normal
	run shareframe-led blinking
	assert_failure 1
	assert_equal "$(shown)" normal
}
