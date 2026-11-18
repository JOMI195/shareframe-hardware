# The passwd wrapper persists root's new hash to /data, so it outlives the tmpfs /etc/shadow.
load ../../support/common

setup() {
	sf_setup
	export SHADOW="$T/shadow" DATA_DIR="$T/data"
	mkdir -p "$DATA_DIR"
	stub busybox "printf 'root:\$6\$new\$hash:1:0:99999:7:::\n' > '$SHADOW'"
}

@test "a changed root password is persisted privately" {
	sh "$PKG/shareframe-init/skel/passwd"
	assert_called 'busybox passwd'
	assert_equal "$(cat "$DATA_DIR/rootpw")" '$6$new$hash'
	assert_equal "$(stat -c %a "$DATA_DIR/rootpw")" 600
}

@test "a failed passwd persists nothing and passes its exit code on" {
	stub busybox 'exit 3'
	run sh "$PKG/shareframe-init/skel/passwd"
	assert_failure 3
	assert_file_not_exists "$DATA_DIR/rootpw"
}
