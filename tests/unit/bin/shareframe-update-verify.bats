# Per-device /data across an update: backed up by the old system, restored by the new one at
# boot right after its migrations, checked in its commit gate. Missing identity or database
# blocks the commit.
load ../../support/common

setup() {
	sf_setup
	fixed_clock
	export VERIFY_ROOT="$T"
	mkdir -p "$T/data/shareframe/db" "$T/data/wifi" "$T/etc"
	echo 'ed25519_private_key = "seed"' > "$T/data/shareframe/.env.secrets.toml"
	echo sqlite > "$T/data/shareframe/db/shareframe.db"
	echo 'network={}' > "$T/data/wifi/wpa_supplicant.conf"
	echo "AP_PASS='x'" > "$T/data/wifi/ap.conf"
	echo VERSION=1.0.0 > "$T/etc/shareframe-release"
}

last() { jq -r ".$1" "$T/data/shareframe/update-verify/last.json"; }

@test "restore with nothing lost reports all present and passes" {
	shareframe-update-verify backup
	echo VERSION=1.1.0 > "$T/etc/shareframe-release"
	run shareframe-update-verify restore
	assert_success
	assert_equal "$(last result)/$(last secrets)/$(last db)/$(last from_version)/$(last to_version)" ok/present/present/1.0.0/1.1.0
}

@test "a release that dropped the identity and the database gets them back, private" {
	shareframe-update-verify backup
	rm -rf "$T/data/shareframe/.env.secrets.toml" "$T/data/shareframe/db"
	run shareframe-update-verify restore
	assert_success
	assert_equal "$(cat "$T/data/shareframe/.env.secrets.toml")" 'ed25519_private_key = "seed"'
	assert_equal "$(stat -c %a "$T/data/shareframe/.env.secrets.toml")" 600
	assert_equal "$(cat "$T/data/shareframe/db/shareframe.db")" sqlite
	assert_equal "$(last secrets)/$(last db)" restored/restored
}

@test "lost Wi-Fi config is restored but never blocks the commit" {
	shareframe-update-verify backup
	rm "$T/data/wifi/ap.conf"
	rm -rf "$T/data/shareframe/update-verify/backup/ap.conf"
	run shareframe-update-verify restore
	assert_success
	assert_equal "$(last ap)" missing
}

@test "an identity gone without a backup blocks the commit" {
	rm "$T/data/shareframe/.env.secrets.toml"
	run shareframe-update-verify restore
	assert_failure 1
	assert_equal "$(last result)/$(last secrets)" failed/missing
}

@test "an empty identity file counts as gone" {
	shareframe-update-verify backup
	: > "$T/data/shareframe/.env.secrets.toml"
	shareframe-update-verify restore
	assert_equal "$(last secrets)" restored
}

@test "check passes with the identity and the database there, and keeps the boot's record" {
	shareframe-update-verify backup
	rm "$T/data/shareframe/.env.secrets.toml"
	shareframe-update-verify restore
	run shareframe-update-verify check
	assert_success
	assert_equal "$(last secrets)" restored
}

@test "check fails without the identity or the database, and writes nothing" {
	rm "$T/data/shareframe/.env.secrets.toml"
	run shareframe-update-verify check
	assert_failure 1
	assert_file_not_exists "$T/data/shareframe/update-verify/last.json"
	echo 'ed25519_private_key = "seed"' > "$T/data/shareframe/.env.secrets.toml"
	rm -rf "$T/data/shareframe/db"
	run shareframe-update-verify check
	assert_failure 1
}
