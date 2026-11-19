# A board's ed25519 identity: the public key and frame id the server pairs it by.
load ../../support/common

setup() { host_setup; }

@test "a known seed gives the known public key and frame id" {
	run "$SRC/scripts/gen-device-key.sh" --selftest
	assert_success
	assert_output --partial 'selftest OK'
}

# bats test_tags=contract
@test "golden identity.txt: the frame id the board derives from the same seed" {
	seed="4Lt78vIuTn62C9832MKfPzKN89RoMzyudfu1W4+0V6M="
	{ echo "seed=$seed"; "$SRC/scripts/gen-device-key.sh" --identity "$seed"; } > "$T/identity.txt"
	assert_golden identity.txt "$T/identity.txt"
}
