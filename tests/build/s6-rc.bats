# The boot's service graph: it compiles, nothing is missing, and the order the design relies on holds.
load ../support/common

setup() {
	host_setup
	SOURCE="$PKG/shareframe-init/source"
	cd "$SOURCE"
}

services() { find . -mindepth 2 -maxdepth 2 -type d | grep -v '/bundles/' | xargs -n1 basename | sort; }
deps() { cat ./*/"$1"/dependencies 2>/dev/null; }
depends_on() { deps "$1" | grep -qx "$2" || fail "$1 does not depend on $2"; }

@test "s6-rc-compile accepts the whole source tree" {
	run /opt/s6-rc/bin/s6-rc-compile "$T/compiled" ./*/
	assert_success
}

@test "every dependency and every bundle member is a service that exists" {
	missing=
	for name in $(cat ./*/*/dependencies bundles/*/contents | sort -u); do
		services | grep -qx "$name" || [ -d "bundles/$name" ] || missing="$missing $name"
	done
	[ -z "$missing" ] || fail "referenced but not defined:$missing"
}

# s6-rc starts the default bundle and everything it depends on; a service outside both never runs.
@test "every service runs at boot" {
	started="$(cat bundles/default/contents)"
	while :; do
		more="$(for s in $started; do echo "$s"; deps "$s"; done | sort -u)"
		[ "$more" = "$started" ] && break
		started="$more"
	done
	missing=
	for svc in $(services); do echo "$started" | grep -qx "$svc" || missing="$missing $svc"; done
	[ -z "$missing" ] || fail "never started:$missing"
}

@test "the order the board relies on" {
	for app in shareframe-display shareframe-dashboard shareframe-websocket shareframe-heartbeat shareframe-update; do
		depends_on "$app" shareframe-db-migrate
	done
	depends_on shareframe-db-migrate seed-shareframe-secrets
	depends_on shareframe-data-dirs mount-data
	depends_on boot-event shareframe-boot-count
	depends_on rauc-mark-good rauc-reconcile
	depends_on dropbear setup-usb0
}

@test "an up or run script calls only image scripts that exist and can run" {
	for f in $(find . -name up -o -name run -o -name finish); do
		for path in $(grep -oE '/usr/(libexec/s6|bin|lib/rauc)/[a-zA-Z0-9_.-]+' "$f"); do
			src="$SRC/br2-external/overlay$path"
			[ "$path" = /usr/lib/rauc/tryboot-backend ] && src="$PKG/shareframe-rauc/files/tryboot-backend"
			case "$path" in /usr/bin/shareframe-[a-z]*|/usr/bin/sysinfo) [ -e "$src" ] || [[ "$path" =~ (websocket|display|dashboard|heartbeat|update|migrate)$ ]] || fail "$f: $path not in the overlay"; continue ;; esac
			[ -e "$src" ] || fail "$f calls $path, which the overlay lacks"
			grep -qE "(/bin/sh|sh) $path" "$f" || [ -x "$src" ] || fail "$f execs $path, which is not executable"
		done
	done
}
