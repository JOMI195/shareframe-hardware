# A signed RAUC bundle from a stored build, and the release metadata the server gets.
load ../support/common

setup() {
	host_setup
	B="$T/build"
	mkdir -p "$B" "$T/rootfs/etc" "$T/boot/A"
	head -c 65536 /dev/urandom > "$T/rootfs/etc/payload"
	mksquashfs "$T/rootfs" "$B/rootfs.squashfs" -quiet -noappend >/dev/null
	echo 'console=ttyS1 rauc.slot=@SLOT@' > "$T/boot/A/cmdline.txt"
	tar -C "$T/boot/A" -cf "$B/boot.tar" .
	printf '{"version": "1.4.0", "config": "fleet-x", "os_sha": "abc1234", "app_sha": "def5678"}\n' > "$B/build.json"
	keys
	export SHAREFRAME_BR_DIR="$T/no-buildroot" SHAREFRAME_RELEASE_CERT="$T/cert.pem" SHAREFRAME_RELEASE_KEY="$T/key.pem"
}

# A throwaway CA and signing cert, generated per test: no key lives in the repo.
keys() {
	openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 -subj /CN=test-ca \
		-keyout "$T/ca.key" -out "$T/ca.pem" 2>/dev/null
	openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj /CN=test-signer \
		-keyout "$T/key.pem" -out "$T/signer.csr" 2>/dev/null
	printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature\n' > "$T/ext.cnf"
	openssl x509 -req -in "$T/signer.csr" -CA "$T/ca.pem" -CAkey "$T/ca.key" -CAcreateserial -days 1 \
		-extfile "$T/ext.cnf" -out "$T/cert.pem" 2>/dev/null
}

release() { "$SRC/scripts/make-release.sh" --from "$B" "$@" 2>&1; }
meta() { jq -r ".$1" "$B/releases/release-1.4.0-dev.json"; }

@test "the bundle verifies against the CA and carries the build's version, slots and hooks" {
	run release
	assert_success
	run rauc info --keyring "$T/ca.pem" "$B/releases/shareframe-1.4.0-dev.raucb"
	assert_success
	assert_output --partial "Verified inline signature by 'CN = test-signer'"
	assert_output --regexp "Compatible:[[:space:]]+'shareframe-pi0w'"
	assert_output --regexp "Version:[[:space:]]+'1\.4\.0'"
	assert_output --regexp "Hooks:[[:space:]]+'install-check'"
	assert_output --regexp "Filename:[[:space:]]+rootfs\.squashfs"
	assert_output --regexp "Filename:[[:space:]]+boot\.tar"
}

@test "the metadata matches the bundle, notes escaped for JSON" {
	printf 'Fixes "quoted" things\n\t- and a tab\n' > "$T/notes.md"
	release --notes "$T/notes.md" --criticality Important >/dev/null
	assert_equal "$(meta sha256)" "$(sha256sum "$B/releases/shareframe-1.4.0-dev.raucb" | cut -d' ' -f1)"
	assert_equal "$(meta size)" "$(stat -c %s "$B/releases/shareframe-1.4.0-dev.raucb")"
	assert_equal "$(meta version)/$(meta criticality)/$(meta os_sha)/$(meta app_sha)" 1.4.0/Important/abc1234/def5678
	assert_equal "$(meta release_notes)" "$(printf 'Fixes "quoted" things\n\t- and a tab')"
	(cd "$B/releases" && sha256sum -c shareframe-1.4.0-dev.raucb.sha256 >/dev/null)
}

@test "a release dir whose version is not the build's is refused" {
	mkdir -p "$T/rel"
	echo SHAREFRAME_VERSION=9.9.9 > "$T/rel/config.env"
	run release --release-dir "$T/rel"
	assert_failure
	assert_output --partial 'release version 9.9.9 != build version 1.4.0'
}

@test "prod mode never falls back to the dev keys" {
	unset SHAREFRAME_RELEASE_CERT SHAREFRAME_RELEASE_KEY
	run release --mode prod
	assert_failure
	assert_output --partial 'prod mode needs SHAREFRAME_RELEASE_CERT'
}

@test "a build without its images is refused" {
	rm "$B/boot.tar"
	run release
	assert_failure
	assert_output --partial 'boot.tar missing'
}
