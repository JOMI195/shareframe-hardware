# Root's password across updates: /etc/shadow is reset each boot, the hash on /data is re-applied.
load ../../support/common

setup() {
	sf_setup
	export DATA_DIR="$T/data" FACTORY_DIR="$T/factory" SHADOW="$T/shadow"
	mkdir -p "$DATA_DIR" "$FACTORY_DIR"
	printf 'root:*:19000:0:99999:7:::\ndaemon:*:19000:0:99999:7:::\n' > "$SHADOW"
}

@test "the persisted hash replaces root's entry only" {
	echo '$6$salt$hash' > "$DATA_DIR/rootpw"
	"$S6/apply-rootpw"
	assert_equal "$(cat "$SHADOW")" 'root:$6$salt$hash:19000:0:99999:7:::
daemon:*:19000:0:99999:7:::'
	assert_equal "$(stat -c %a "$SHADOW")" 600
}

@test "on first boot the factory hash is persisted and applied" {
	echo '$6$factory$hash' > "$FACTORY_DIR/rootpw"
	"$S6/apply-rootpw"
	assert_equal "$(cat "$DATA_DIR/rootpw")" '$6$factory$hash'
	assert_equal "$(head -1 "$SHADOW")" 'root:$6$factory$hash:19000:0:99999:7:::'
}

@test "no hash anywhere leaves the baked shadow alone" {
	before="$(cat "$SHADOW")"
	"$S6/apply-rootpw"
	assert_equal "$(cat "$SHADOW")" "$before"
}
