# First-boot secrets (frame identity, initial password): factory store first; never replaced.
load ../../support/common

setup() {
	sf_setup
	export SECRETS="$T/data/.env.secrets.toml" FACTORY_DIR="$T/factory" SHARE_DIR="$T/share" CONSOLE="$T/console"
	mkdir -p "$T/data" "$FACTORY_DIR" "$SHARE_DIR"
	echo 'dashboard_initial_password = ""' > "$SHARE_DIR/.env.secrets.toml.template"
}

@test "the provisioned identity is seeded private" {
	echo 'ed25519_private_key = "seed"' > "$FACTORY_DIR/.env.secrets.toml"
	"$S6/seed-shareframe-secrets"
	assert_equal "$(cat "$SECRETS")" 'ed25519_private_key = "seed"'
	assert_equal "$(stat -c %a "$SECRETS")" 600
}

@test "an identity on /data survives everything after" {
	echo 'ed25519_private_key = "mine"' > "$SECRETS"
	echo 'ed25519_private_key = "seed"' > "$FACTORY_DIR/.env.secrets.toml"
	"$S6/seed-shareframe-secrets"
	assert_equal "$(cat "$SECRETS")" 'ed25519_private_key = "mine"'
}

@test "without a provisioned one the template skeleton is used" {
	"$S6/seed-shareframe-secrets"
	assert_equal "$(cat "$SECRETS")" 'dashboard_initial_password = ""'
}
