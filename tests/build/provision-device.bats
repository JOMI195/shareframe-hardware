# A device's flash image: the fleet image with its factory files in p5, nothing else touched.
load ../support/common

setup() {
	host_setup
	B="$T/build"
	D="$T/device"
	mkdir -p "$B" "$D/factory"
	card "$B/sdcard.img"
	echo '{"version": "1.4.0"}' > "$B/build.json"
	printf 'ed25519_private_key = "seed"\n' > "$D/factory/.env.secrets.toml"
	printf "AP_SSID='frame'\nAP_PASS='hotspot-1'\n" > "$D/factory/ap.conf"
}

# The genimage layout in small: p1-p3, an extended p4 holding p5 (factory, FAT) and p6.
card() {
	truncate -s 48M "$1"
	sfdisk -q "$1" <<SF
label: dos
start=2048, size=8M, type=c
size=8M, type=83
size=8M, type=83
type=5
size=8M, type=c
type=83
SF
	p5="$(sfdisk -J "$1" | jq '.partitiontable.partitions[] | select(.node | endswith("5")) | .start')"
	mkfs.vfat -C "$T/p5.img" 8188 >/dev/null
	dd if="$T/p5.img" of="$1" bs=512 seek="$p5" conv=notrunc status=none
	printf 'slot-a' | dd of="$1" bs=512 seek=$((2048 + 16384)) conv=notrunc status=none
	P5_OFFSET=$((p5 * 512))
}

region() { dd if="$1" bs=512 skip="$2" count="$3" status=none | sha256sum | cut -d' ' -f1; }

@test "the factory files land in p5 of a copy, the fleet image stays as it was" {
	before="$(sha256sum "$B/sdcard.img")"
	run "$SRC/scripts/provision-device.sh" --device "$D" --from "$B" --out "$T/out.img"
	assert_success
	assert_equal "$(sha256sum "$B/sdcard.img")" "$before"
	run mtype -i "$T/out.img@@$P5_OFFSET" ::/ap.conf
	assert_output --partial "AP_PASS='hotspot-1'"
	run mtype -i "$T/out.img@@$P5_OFFSET" ::/.env.secrets.toml
	assert_output --partial ed25519_private_key
}

@test "only p5 changes" {
	"$SRC/scripts/provision-device.sh" --device "$D" --from "$B" --out "$T/out.img" >/dev/null
	assert_equal "$(region "$T/out.img" 0 $((P5_OFFSET / 512)))" "$(region "$B/sdcard.img" 0 $((P5_OFFSET / 512)))"
}

@test "a device without an identity is refused" {
	: > "$D/factory/.env.secrets.toml"
	run "$SRC/scripts/provision-device.sh" --device "$D" --from "$B" --out "$T/out.img"
	assert_failure
	assert_output --partial 'no ed25519_private_key'
	assert_file_not_exists "$T/out.img"
}
