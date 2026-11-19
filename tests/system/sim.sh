#!/usr/bin/env bash
# shellcheck disable=SC2016  # remote commands expand on the board
# Simulated Shareframe board: the real image under QEMU raspi0, hwsim WiFi
# radios with a home/office router and a phone, the fake Shareframe server,
# and a firmware stand-in that boots the A/B slot like the Pi firmware does.
# See README.tests.md, "System tier".
set -euo pipefail

HW="$(cd "$(dirname "$0")/../.." && pwd)"
SELF="$HW/tests/system/sim.sh"
BOARD="${SHAREFRAME_BOARD_DIR:-$(cd "$HW/.." && pwd)/shareframe-board}"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/shareframe-sim"
# Under $HOME so Docker Desktop can mount it into the test runner.
RUN="$CACHE/run"
BR="$CACHE/buildroot"
BUILDS="$CACHE/builds"
IMAGE="$CACHE/sim.img"
BUNDLES="$CACHE/bundles"
CONFIG="$CACHE/config"
KEY="$CACHE/ssh/id_ed25519"

SSH_PORT="${SIM_SSH_PORT:-2222}"
HTTP_PORT="${SIM_HTTP_PORT:-8090}"
SERVER_PORT="${SIM_SERVER_PORT:-9000}"
SERVER="http://127.0.0.1:$SERVER_PORT"
SERVER_IMAGE=shareframe-sim-fake-server
SERVER_NAME=shareframe-sim-fake-server
RUNNER_IMAGE=shareframe-sim-runner
BASE_VERSION="${SIM_BASE_VERSION:-1.0.0}"
UPDATE_VERSION="${SIM_UPDATE_VERSION:-1.0.1}"
MIGRATION_VERSION="${SIM_MIGRATION_VERSION:-1.0.2}"
SIM_ARGS="initcall_blacklist=bcm2835_power_driver_init,bcm2835_wdt_driver_init mac80211_hwsim.radios=4"

die() { echo "sim: $*" >&2; exit 1; }
log() { echo "sim: $*" >&2; }

need() {
	local missing=()
	for t in "$@"; do command -v "$t" >/dev/null || missing+=("$t"); done
	[ ${#missing[@]} -eq 0 ] || die "missing host tools: ${missing[*]}"
}

wait_for() { # <secs> <what> <cmd...>
	local secs="$1" what="$2"; shift 2
	local deadline=$((SECONDS + secs))
	until "$@" >/dev/null 2>&1; do
		[ $SECONDS -lt $deadline ] || die "timed out after ${secs}s waiting for $what"
		sleep 1
	done
}

alive() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }
running() { alive "$RUN/firmware.pid" || alive "$RUN/qemu.pid"; }

# Without a resolver (hotspot mode) dropbear needs about 5 s before its banner; reuse one connection.
bssh() {
	ssh -i "$RUN/id_ed25519" -p "$SSH_PORT" \
		-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR \
		-o ConnectTimeout=30 -o BatchMode=yes \
		-o ControlMaster=auto -o ControlPath="$RUN/ssh-%C" -o ControlPersist=120 root@127.0.0.1 "$@"
}

connected() { [ "$(bssh cat /run/shareframe/wifi-mode 2>/dev/null)" = connected ]; }

# The routers and the phone live in the guest, so every boot needs them again. When the
# board's first scan beat them and it opened the hotspot, ask it to retry like the dashboard does.
bring_up_world() {
	wait_for 300 "ssh on the board" bssh true
	local args=()
	# One boot without the uplink: set by the specs through $RUN/uplink-down.
	if [ -f "$RUN/uplink-down" ]; then rm -f "$RUN/uplink-down"; args=(--uplink-down); fi
	bssh /usr/libexec/sim/world init "${args[@]}"
	local deadline=$((SECONDS + 120)) mode
	while [ $SECONDS -lt $deadline ]; do
		mode="$(bssh cat /run/shareframe/wifi-mode 2>/dev/null || true)"
		[ "$mode" = connected ] && return 0
		[ "$mode" = ap ] && { bssh ': > /run/shareframe/wifi-retry-requested'; return 0; }
		sleep 3
	done
}

port_free() { ! (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# ---- image

# configs/sim plus what must never be in git: the ssh key and the frame identity, made per machine.
prepare_config() {
	need ssh-keygen openssl
	rm -rf "$CONFIG" && cp -r "$HW/configs/sim" "$CONFIG"
	if [ ! -f "$KEY" ]; then
		mkdir -p "$(dirname "$KEY")"
		ssh-keygen -q -t ed25519 -N '' -C shareframe-sim -f "$KEY"
	fi
	install -D -m 600 "$KEY.pub" "$CONFIG/overlay/root/.ssh/authorized_keys"
	if [ ! -f "$CACHE/secrets.toml" ]; then
		printf 'dashboard_initial_password = "e2e-password"\n' > "$CONFIG/factory/.env.secrets.toml"
		"$HW/scripts/gen-device-key.sh" --device "$CONFIG" >/dev/null
		install -m 600 "$CONFIG/factory/.env.secrets.toml" "$CACHE/secrets.toml"
	fi
	install -m 600 "$CACHE/secrets.toml" "$CONFIG/factory/.env.secrets.toml"
}

build_image() { # <version> [--with-migration]
	local version="$1" log="$CACHE/build-$1.log"
	mkdir -p "$CACHE"
	rm -rf "${BUILDS:?}/sim-$version"
	prepare_config
	# Buildroot keeps overlay files in its target from earlier builds; only this build may carry it.
	rm -f "$BR/output/target/usr/share/shareframe/system-migrations/990-sim-break-data.sh"
	if [ "${2:-}" = --with-migration ]; then
		install -D -m 755 "$HW/tests/system/fixtures/990-sim-break-data.sh" \
			"$CONFIG/overlay/usr/share/shareframe/system-migrations/990-sim-break-data.sh"
	fi
	log "building sim $version (log: $log)"
	(cd "$HW" && SHAREFRAME_BR_DIR="$BR" SHAREFRAME_ARTIFACTS_DIR="$BUILDS" \
		./automation.sh build "$CONFIG" --version "$version") > "$log" 2>&1 \
		|| { tail -n 30 "$log" >&2; die "build failed, see $log"; }
}

cmd_build() {
	need make rsync mcopy sfdisk
	local version="${1:-$BASE_VERSION}"
	build_image "$version"
	SHAREFRAME_BR_DIR="$BR" "$HW/scripts/provision-device.sh" \
		--device "$CONFIG" --from "$BUILDS/sim-$version" --out "$IMAGE" > "$CACHE/provision.log" 2>&1 \
		|| { cat "$CACHE/provision.log" >&2; die "provisioning failed"; }
	echo "$version" > "$CACHE/base-version"
	log "image ready: $IMAGE (version $version)"
}

# ---- firmware stand-in: picks the slot, boots it, and starts over on every reboot

firmware() {
	local start size tryboot cfg prefix append n=0 qpid
	read -r start size < "$RUN/boot-part"
	while [ ! -f "$RUN/stop" ]; do
		tryboot=0
		if [ -f "$RUN/serial.log" ]; then
			grep -aq "Restarting system with command '0 tryboot'" "$RUN/serial.log" && tryboot=1
			cat "$RUN/serial.log" >> "$RUN/console.log"
			if grep -aq "reboot: Power down" "$RUN/serial.log"; then
				rm -f "$RUN/serial.log"
				echo "$(date -Is) powered off" >> "$RUN/boots.log"
				break
			fi
			rm -f "$RUN/serial.log"
		fi

		rm -f "$RUN/boot.vfat"
		qemu-img dd -f qcow2 -O raw bs=1M skip=$((start / 2048)) count=$((size / 2048)) \
			if="$RUN/sd.qcow2" of="$RUN/boot.vfat"
		cfg=config.txt
		[ "$tryboot" = 1 ] && cfg=tryboot.txt
		prefix="$(mtype -i "$RUN/boot.vfat" "::$cfg" | tr -d '\r' | sed -n 's|^os_prefix=\(.*\)/$|\1|p')"
		[ -n "$prefix" ] || { echo "$(date -Is) no os_prefix in $cfg" >> "$RUN/boots.log"; break; }
		rm -rf "${RUN:?}/boot" && mkdir "$RUN/boot"
		for f in zImage bcm2835-rpi-zero-w.dtb initramfs.cpio.gz cmdline.txt; do
			mcopy -n -i "$RUN/boot.vfat" "::$prefix/$f" "$RUN/boot/$f"
		done

		append="$(tr -d '\r\n' < "$RUN/boot/cmdline.txt") $SIM_ARGS"
		if [ "$tryboot" = 1 ] && [ -f "$RUN/break-trial" ]; then
			append="$append rdinit=/sim-broken-trial"
			rm -f "$RUN/break-trial"
		fi
		n=$((n + 1))
		echo "$(date -Is) boot $n slot=$prefix from=$cfg" >> "$RUN/boots.log"

		qemu-system-arm -M raspi0 -display none -no-reboot \
			-chardev "socket,id=con,path=$RUN/console.sock,server=on,wait=off,logfile=$RUN/serial.log" \
			-serial null -serial chardev:con \
			-qmp "unix:$RUN/qmp.sock,server=on,wait=off" \
			-kernel "$RUN/boot/zImage" -dtb "$RUN/boot/bcm2835-rpi-zero-w.dtb" \
			-initrd "$RUN/boot/initramfs.cpio.gz" -append "$append" \
			-drive "if=sd,format=qcow2,file=$RUN/sd.qcow2" \
			-netdev "user,id=ctl,restrict=on,net=10.55.0.0/24,host=10.55.0.2,hostfwd=tcp:127.0.0.1:$SSH_PORT-10.55.0.1:22,hostfwd=tcp:127.0.0.1:$HTTP_PORT-10.55.0.1:80" \
			-device usb-net,netdev=ctl,mac=52:54:00:5f:00:01 \
			-netdev user,id=up,net=10.0.2.0/24 \
			-device usb-net,netdev=up,mac=52:54:00:5f:00:02 &
		qpid=$!
		echo "$qpid" > "$RUN/qemu.pid"
		( bring_up_world && echo "$(date -Is) world up after boot $n" ) >> "$RUN/firmware.log" 2>&1 &
		# Without the BCM2835 watchdog the kernel cannot reset the SoC and halts instead.
		while kill -0 "$qpid" 2>/dev/null; do
			if [ -f "$RUN/stop" ] || grep -aqE "Reboot failed -- System halted|reboot: Power down" "$RUN/serial.log" 2>/dev/null; then
				sleep 0.5
				kill "$qpid" 2>/dev/null || true
			fi
			# The plug pulled: no shutdown in the guest. QEMU itself quits cleanly, so the card keeps
			# what was written to it (a SIGKILL would drop the qcow2 metadata QEMU still holds).
			if [ -f "$RUN/power-cut" ]; then
				rm -f "$RUN/power-cut"
				echo "$(date -Is) power cut" >> "$RUN/boots.log"
				printf '{"execute":"qmp_capabilities"}\n{"execute":"quit"}\n' \
					| socat - "UNIX-CONNECT:$RUN/qmp.sock" >/dev/null 2>&1 || kill "$qpid" 2>/dev/null || true
			fi
			sleep 0.5
		done
		wait "$qpid" || true
		rm -f "$RUN/qemu.pid"
	done
}

# ---- fake server

server_start() {
	docker build -q -t "$SERVER_IMAGE" "$BOARD/tests/e2e/fake-server" >/dev/null
	docker rm -f "$SERVER_NAME" >/dev/null 2>&1 || true
	docker run -d --rm --name "$SERVER_NAME" -p "127.0.0.1:$SERVER_PORT:9000" \
		-e PUBLIC_URL="http://10.0.2.2:$SERVER_PORT" -v "$BUNDLES:/bundles:ro" "$SERVER_IMAGE" >/dev/null
	wait_for 30 "fake server" curl -fsS "$SERVER/__test/state"
}

post() { # <path> [json]
	curl -fsS -X POST -H 'Content-Type: application/json' -d "${2:-{\}}" "$SERVER$1"
	echo
}

# ---- lifecycle

cmd_up() {
	need qemu-system-arm qemu-img mtype mcopy sfdisk jq ssh curl docker setsid socat
	running && die "already up (sim.sh down first)"
	[ -f "$IMAGE" ] || die "no image yet, run: sim.sh build"
	for p in "$SSH_PORT" "$HTTP_PORT" "$SERVER_PORT"; do
		port_free "$p" || die "port $p is in use (set SIM_SSH_PORT / SIM_HTTP_PORT / SIM_SERVER_PORT)"
	done

	rm -rf "$RUN" && mkdir -p "$RUN" "$BUNDLES"
	install -m 600 "$KEY" "$RUN/id_ed25519"
	server_start
	qemu-img create -q -f qcow2 -b "$IMAGE" -F raw "$RUN/sd.qcow2" 1G
	sfdisk -J "$IMAGE" | jq -r '.partitiontable.partitions[0] | "\(.start) \(.size)"' > "$RUN/boot-part"
	local start size
	read -r start size < "$RUN/boot-part"
	[ $((start % 2048)) -eq 0 ] && [ $((size % 2048)) -eq 0 ] || die "boot partition is not MiB-aligned"

	setsid "$SELF" _firmware > "$RUN/firmware.log" 2>&1 < /dev/null &
	echo $! > "$RUN/firmware.pid"

	log "booting (console: sim.sh logs)"
	wait_for 300 "the routers around the board" bssh test -f /run/sim/ready
	wait_for 180 "the dashboard" curl -fsS "http://127.0.0.1:$HTTP_PORT/api/auth/status"
	( wait_for 300 "the board to join the home network" connected ) \
		|| log "board not connected yet: $(bssh cat /run/shareframe/wifi-mode.json 2>/dev/null)"
	log "up: dashboard http://127.0.0.1:$HTTP_PORT  server $SERVER  ssh: sim.sh ssh"
}

cmd_down() {
	[ -d "$RUN" ] || { docker rm -f "$SERVER_NAME" >/dev/null 2>&1 || true; return 0; }
	touch "$RUN/stop"
	for pidfile in "$RUN/qemu.pid" "$RUN/firmware.pid"; do
		alive "$pidfile" && kill "$(cat "$pidfile")" 2>/dev/null || true
	done
	local deadline=$((SECONDS + 10))
	while running && [ $SECONDS -lt $deadline ]; do sleep 0.5; done
	for pidfile in "$RUN/qemu.pid" "$RUN/firmware.pid"; do
		alive "$pidfile" && kill -9 "$(cat "$pidfile")" 2>/dev/null || true
	done
	pkill -f -- "file=$RUN/sd.qcow2" 2>/dev/null || true
	docker rm -f "$SERVER_NAME" >/dev/null 2>&1 || true
	rm -rf "$RUN"
	log "down"
}

cmd_purge() {
	local yes=0
	[ "${1:-}" = --yes ] && yes=1
	echo "This deletes everything the simulator created:"
	[ -d "$RUN" ] && echo "  $RUN ($(du -sh "$RUN" 2>/dev/null | cut -f1)) and the running board"
	[ -d "$CACHE" ] && echo "  $CACHE ($(du -sh "$CACHE" 2>/dev/null | cut -f1)): Buildroot tree, images, bundles, logs"
	for img in "$SERVER_IMAGE" "$RUNNER_IMAGE"; do
		docker image inspect "$img" >/dev/null 2>&1 && echo "  docker image $img"
	done
	if [ "$yes" = 0 ]; then
		read -r -p "Delete? [y/N] " answer
		[ "$answer" = y ] || [ "$answer" = Y ] || { echo "nothing deleted"; return 0; }
	fi
	cmd_down
	if [ -d "$CACHE" ]; then
		rm -rf "$CACHE" 2>/dev/null || { chmod -R u+w "$CACHE"; rm -rf "$CACHE"; }
	fi
	docker rmi -f "$SERVER_IMAGE" "$RUNNER_IMAGE" >/dev/null 2>&1 || true

	local left=()
	[ -e "$RUN" ] && left+=("$RUN")
	[ -e "$CACHE" ] && left+=("$CACHE")
	for img in "$SERVER_IMAGE" "$RUNNER_IMAGE"; do
		docker image inspect "$img" >/dev/null 2>&1 && left+=("image $img")
	done
	docker container inspect "$SERVER_NAME" >/dev/null 2>&1 && left+=("container $SERVER_NAME")
	pgrep -f "qemu-system-arm.*shareframe-sim" >/dev/null && left+=("qemu process")
	[ ${#left[@]} -eq 0 ] || die "still there: ${left[*]}"
	echo "purged"
}

# ---- inspection

cmd_status() {
	running || { echo "board: down"; return 0; }
	echo "== boots"
	tail -n 5 "$RUN/boots.log" 2>/dev/null || true
	echo "== board"
	bssh 'echo "slot booted=$(shareframe-slot booted) pending=$(shareframe-slot pending)"
		sed -n "s/^VERSION=/version=/p" /etc/shareframe-release
		echo "wifi $(cat /run/shareframe/wifi-mode.json 2>/dev/null)"
		/usr/libexec/sim/world status | sed "s/^/world /"
		for s in /run/service/*; do
			[ -d "$s" ] || continue
			echo "service $(basename "$s") $(s6-svstat -o up,pid "$s" 2>/dev/null)"
		done' || echo "board not reachable over ssh"
	echo "== server"
	curl -fsS "$SERVER/__test/state" | jq -c '{connectedFrames, tokenRequests, heartbeats: (.heartbeats | length),
		lastHeartbeat: (.heartbeats[-1] // null), bundleDownloads}' || echo "fake server not reachable"
}

cmd_logs() {
	local follow=0
	[ "${1:-}" = -f ] && { follow=1; shift; }
	local svc="${1:-}"
	if [ -z "$svc" ]; then
		[ -d "$RUN" ] || die "not up"
		if [ "$follow" = 1 ]; then
			tail -n 100 -F "$RUN/serial.log"
		else
			cat "$RUN/console.log" "$RUN/serial.log" 2>/dev/null | tail -n "${LINES:-200}"
		fi
		return
	fi
	local file="/var/log/shareframe/shareframe-$svc.log"
	[ "$svc" = system ] && file=/var/log/messages
	if [ "$follow" = 1 ]; then bssh tail -n 100 -f "$file"; else bssh tail -n "${LINES:-200}" "$file"; fi
}

cmd_panel() {
	running || die "not up"
	local out="${1:-$RUN/panel.png}"
	bssh cat /run/shareframe/panel/panel.json
	echo
	bssh cat /run/shareframe/panel/panel.pbm > "$RUN/panel.pbm"
	python3 -I - "$RUN/panel.pbm" "$out" <<'EOF'
import struct, sys, zlib
data = open(sys.argv[1], 'rb').read()
parts = data.split(b'\n', 2)
w, h = map(int, parts[1].split())
bits = parts[2]
row = (w + 7) // 8
raw = b''.join(b'\x00' + bytes(255 - b for b in bits[y * row:(y + 1) * row]) for y in range(h))
chunk = lambda t, d: struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 1, 0, 0, 0, 0)) \
    + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')
open(sys.argv[2], 'wb').write(png)
EOF
	echo "$out"
}

# ---- knobs

cmd_wifi() {
	running || die "not up"
	case "${1:-}" in
		home|office) bssh /usr/libexec/sim/world ap "$@" ;;
		uplink|phone) bssh /usr/libexec/sim/world "$@" ;;
		status|"")
			bssh 'cat /run/shareframe/wifi-mode.json; echo; /usr/libexec/sim/world status' ;;
		*) die "wifi home|office up|down|psk <pass> | uplink up|down | phone join [ssid pass]|leave|get <path> | status" ;;
	esac
}

cmd_server() {
	case "${1:-}" in
		picture)
			local fixture="${2:-gradient.jpg}" expires="${3:-3600}"
			[ -f "$fixture" ] || fixture="$BOARD/tests/e2e/fixtures/$fixture"
			[ -f "$fixture" ] || die "no such picture: ${2:-}"
			base64 -w0 "$fixture" | jq -Rc --argjson e "$expires" '{data: ., expiresInSecs: $e, sender: "sim"}' \
				| curl -fsS -X POST -H 'Content-Type: application/json' -d @- "$SERVER/__test/picture"
			echo ;;
		remove)
			shift; [ $# -gt 0 ] || die "remove <id>..."
			post /__test/send "$(printf '%s\n' "$@" | jq -sc '{type: "clear_specific_sent_images", sent_image_ids: map(tonumber)}')" ;;
		clear) post /__test/send '{"type":"clear_display"}' ;;
		send) post /__test/send "${2:?send <json>}" ;;
		garbage)
			curl -fsS -X POST -H 'Content-Type: text/plain' -d "${2:-not json {}" "$SERVER/__test/send-raw"; echo ;;
		outage|unregistered)
			case "${2:-}" in on) post "/__test/$1" '{"on":true}' ;; off) post "/__test/$1" '{"on":false}' ;; *) die "$1 on|off" ;; esac ;;
		disconnect) post /__test/disconnect "$([ -n "${2:-}" ] && echo "{\"code\":$2}" || echo '{}')" ;;
		state) curl -fsS "$SERVER/__test/state" | jq . ;;
		reset) post /__test/reset ;;
		*) die "server picture [file] [expires]|remove <id>...|clear|send <json>|garbage [text]|outage on|off|unregistered on|off|disconnect [code]|state|reset" ;;
	esac
}

cmd_update() {
	case "${1:-}" in
		bundle)
			local v="${2:?bundle <version> [--foreign-key | --with-migration]}" opt="${3:-}" name="shareframe-$2"
			local signer=()
			case "$opt" in
				--foreign-key)
					# A key the board's keyring has never seen, made here and never kept in git.
					local fk="$CACHE/foreign"
					if [ ! -f "$fk/key.pem" ]; then
						mkdir -p "$fk"
						openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=not-shareframe \
							-keyout "$fk/key.pem" -out "$fk/cert.pem" >/dev/null 2>&1 || die "foreign key failed"
					fi
					signer=(SHAREFRAME_RELEASE_CERT="$fk/cert.pem" SHAREFRAME_RELEASE_KEY="$fk/key.pem")
					name="$name-foreign"
					[ -d "$BUILDS/sim-$v" ] || build_image "$v" ;;
				--with-migration) build_image "$v" --with-migration ;;
				'') build_image "$v" ;;
				*) die "bundle: unknown option $opt" ;;
			esac
			env "${signer[@]}" SHAREFRAME_BR_DIR="$BR" "$HW/scripts/make-release.sh" --mode dev --from "$BUILDS/sim-$v" \
				> "$CACHE/release-$v.log" 2>&1 || { tail -n 20 "$CACHE/release-$v.log" >&2; die "bundle failed"; }
			mkdir -p "$BUNDLES"
			cp "$BUILDS/sim-$v/releases/shareframe-$v-dev.raucb" "$BUNDLES/$name.raucb"
			echo "$BUNDLES/$name.raucb" ;;
		offer)
			local v="${2:?offer <version> [--corrupt] [--criticality C] [--notes TEXT]}" corrupt=false crit=Minor notes="Simulator release $2"
			shift 2
			while [ $# -gt 0 ]; do
				case "$1" in
					--corrupt) corrupt=true; shift ;;
					--criticality) crit="$2"; shift 2 ;;
					--notes) notes="$2"; shift 2 ;;
					*) die "offer: unknown option $1" ;;
				esac
			done
			[ -f "$BUNDLES/shareframe-$v.raucb" ] || die "no bundle for $v, run: sim.sh update bundle $v"
			post /__test/release "$(jq -nc --arg v "$v" --arg c "$crit" --arg n "$notes" --argjson corrupt "$corrupt" \
				'{version: $v, bundleFile: "shareframe-\($v).raucb", criticality: $c, release_notes: $n,
				  release_date: (now | todate), corrupt: $corrupt}')" ;;
		break-trial)
			running || die "not up"
			touch "$RUN/break-trial"
			echo "the next trial boot panics" ;;
		power-cut)
			running || die "not up"
			touch "$RUN/power-cut"
			echo "the board loses power and boots again" ;;
		*) die "update bundle <version> [--foreign-key | --with-migration] | offer <version> [--corrupt] [--criticality C] [--notes TEXT] | break-trial | power-cut" ;;
	esac
}

# Playwright in a container; the board repo's e2e helpers are mounted where @board/* points.
runner() { # [docker args] -- <command>
	docker build -q -f "$HW/tests/system/runner.Dockerfile" -t "$RUNNER_IMAGE" "$BOARD/tests/e2e" >/dev/null
	local extra=()
	while [ "$1" != -- ]; do extra+=("$1"); shift; done
	shift
	docker run --rm --ipc=host -u "$(id -u):$(id -g)" -e CI=1 -e HOME=/tmp "${extra[@]}" \
		-v "$HW/tests/system:/w/shareframe-hardware/tests/system:ro" \
		-v "$BOARD/tests/e2e/support:/w/shareframe-board/tests/e2e/support:ro" \
		-v "$BOARD/tests/e2e/fixtures:/w/shareframe-board/tests/e2e/fixtures:ro" \
		-w /w/shareframe-hardware/tests/system "$RUNNER_IMAGE" "$@"
}

# Specs and cross-repo imports resolve, without a board.
cmd_check() {
	[ -d "$BOARD/tests/e2e/support" ] || die "board repo not found at $BOARD (set SHAREFRAME_BOARD_DIR)"
	runner -- npx playwright test --list --reporter=list "$@"
}

cmd_test() {
	running || die "not up"
	[ -f "$BUNDLES/shareframe-$UPDATE_VERSION.raucb" ] || cmd_update bundle "$UPDATE_VERSION" >/dev/null
	[ -f "$BUNDLES/shareframe-$UPDATE_VERSION-foreign.raucb" ] || cmd_update bundle "$UPDATE_VERSION" --foreign-key >/dev/null
	[ -f "$BUNDLES/shareframe-$MIGRATION_VERSION.raucb" ] || cmd_update bundle "$MIGRATION_VERSION" --with-migration >/dev/null
	local host=127.0.0.1 net=(--network host)
	if docker info --format '{{.OperatingSystem}}' 2>/dev/null | grep -q 'Docker Desktop'; then
		host=host.docker.internal net=()
	fi
	rm -rf "$CACHE/report" && mkdir -p "$CACHE/report"
	local status=0
	runner "${net[@]}" -e SIM_UPDATE_VERSION="$UPDATE_VERSION" -e SIM_MIGRATION_VERSION="$MIGRATION_VERSION" \
		-e E2E_BASE_URL="http://$host:$HTTP_PORT" -e FAKE_SERVER_URL="http://$host:$SERVER_PORT" \
		-e PANEL_DIR=/run/shareframe/panel -e E2E_REPORT_DIR=/report/html -e E2E_RESULTS_DIR=/report/results \
		-e BOARD_SSH="-i /simrun/id_ed25519 -p $SSH_PORT -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=30 -o ControlMaster=auto -o ControlPath=/tmp/sim-%C -o ControlPersist=300 root@$host" \
		-v "$RUN:/simrun" -v "$CACHE/report:/report" -- npx playwright test "$@" || status=$?
	[ "$status" = 0 ] || collect "$CACHE/report/board"
	echo "report: $CACHE/report/html/index.html"
	return $status
}

# Board logs and the serial console, kept after `down` for a failed run.
collect() { # <dir>
	local dir="$1"
	mkdir -p "$dir"
	cp "$RUN"/{console.log,serial.log,boots.log,firmware.log} "$dir/" 2>/dev/null || true
	bssh 'tar -cz -C / var/log run/shareframe/wifi-mode.json data/rauc 2>/dev/null' > "$dir/board-logs.tar.gz" || true
	curl -fsS "$SERVER/__test/state" | jq 'del(.heartbeats[:-5])' > "$dir/server-state.json" 2>/dev/null || true
	log "board logs: $dir"
}

cmd_deploy() {
	running || die "not up"
	local base n v
	base="$(cat "$CACHE/base-version" 2>/dev/null || echo "$BASE_VERSION")"
	n=$(( $(cat "$CACHE/deploy-counter" 2>/dev/null || echo 0) + 1 ))
	echo "$n" > "$CACHE/deploy-counter"
	v="${base%.*}.$(( ${base##*.} + n ))"
	cmd_update bundle "$v" >/dev/null
	log "installing $v on the board"
	bssh 'cat > /data/updates/deploy.raucb' < "$BUNDLES/shareframe-$v.raucb"
	bssh 'rauc install /data/updates/deploy.raucb && rm -f /data/updates/deploy.raucb && : > /run/tryboot &&
		{ (sleep 1; s6-linux-init-shutdown -r now) >/dev/null 2>&1 & }'
	sleep 5
	wait_for 300 "the board to come back" bssh true
	bssh 'echo "slot $(shareframe-slot booted), $(sed -n "s/^VERSION=/version /p" /etc/shareframe-release)"'
}

usage() {
	cat <<'EOF'
usage: tests/system/sim.sh <command>

  build [version]          build + provision the sim image (default 1.0.0)
  up | down | reset        start, stop (removes all run state), restart from a pristine card
  purge [--yes]            delete everything the simulator created (cache, images, run state)
  status                   slots, version, wifi state, services, server state
  ssh [cmd]                shell on the board
  console                  serial console (Ctrl-] leaves)
  logs [-f] [service]      serial console history, or a service log (display, dashboard, ws, ..., system)
  panel [out.png]          what the e-paper would show
  collect [dir]            copy board logs, serial console and server state (default: report/board)
  wifi ...                 home|office up|down|psk <pass>, uplink up|down,
                           phone join [ssid pass]|leave|get <path>, status
  server ...               picture [file] [expires], remove <id>..., clear, send <json>, garbage,
                           outage on|off, unregistered on|off, disconnect [code], state, reset
  update ...               bundle <version>, offer <version> [--corrupt] [--criticality C], break-trial,
                           power-cut (pull the plug; the board boots again)
  deploy                   build the working tree into a bundle and install it with RAUC
  test [playwright args]   run tests/system/specs against the running board
  check                    list the specs in the runner: imports and types resolve, no board needed
EOF
}

cmd="${1:-}"
[ $# -gt 0 ] && shift
case "$cmd" in
	build) cmd_build "$@" ;;
	up) cmd_up ;;
	down) cmd_down ;;
	reset) cmd_down; cmd_up ;;
	purge) cmd_purge "$@" ;;
	status) cmd_status ;;
	ssh) running || die "not up"; bssh "$@" ;;
	console) running || die "not up"; socat -,rawer,escape=0x1d "UNIX-CONNECT:$RUN/console.sock" ;;
	logs) cmd_logs "$@" ;;
	panel) cmd_panel "$@" ;;
	collect) running || die "not up"; collect "${1:-$CACHE/report/board}" ;;
	wifi) cmd_wifi "$@" ;;
	server) cmd_server "$@" ;;
	update) cmd_update "$@" ;;
	deploy) cmd_deploy ;;
	test) cmd_test "$@" ;;
	check) cmd_check "$@" ;;
	_firmware) firmware ;;
	*) usage; [ -z "$cmd" ] || exit 1 ;;
esac
