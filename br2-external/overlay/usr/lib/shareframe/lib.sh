# Shared helpers, sourced: . "${SF_LIB:-/usr/lib/shareframe/lib.sh}"
# shellcheck shell=sh

# json_escape <string>: the string as the inside of a JSON string literal.
json_escape() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g' -e 's/\r/\\r/g' \
		| awk 'NR > 1 { printf "\\n" } { gsub(/[\001-\010\013\014\016-\037]/, ""); printf "%s", $0 }'
}

# board_serial: the Pi's serial without leading zeros; empty when there is none.
board_serial() { sed -n 's/^Serial\s*:\s*0*//p' "${CPUINFO:-/proc/cpuinfo}" 2>/dev/null | head -1; }

# board_name: shareframe-board-<last 4 of the serial>, both the hostname and the hotspot SSID.
board_name() {
	s="$(board_serial)"
	printf 'shareframe-board-%s\n' "$(printf '%s' "$s" | tail -c 4 | tr 'a-f' 'A-F')"
}

# write_durable <file> <value>: replace the file whole and push it to the card, so a power
# cut seconds later cannot take it.
write_durable() { printf '%s\n' "$2" > "$1.tmp" && mv "$1.tmp" "$1" && sync; }
