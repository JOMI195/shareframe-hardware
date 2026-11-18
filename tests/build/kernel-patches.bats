# The kernel patches still apply to the kernel the image builds. Needs the Buildroot tree;
# without it these skip, and fail under ./test.sh build --strict.
load ../support/common

setup() {
	host_setup
	LINUX="$(ls -d "$SRC"/build/buildroot/output/build/linux-[0-9]* 2>/dev/null | head -1)"
	if [ -z "$LINUX" ]; then
		[ "${STRICT:-0}" = 1 ] && fail "no kernel tree under build/buildroot"
		skip "no Buildroot kernel tree"
	fi
}

@test "the image's kernel patches are in the tree it builds" {
	for p in "$SRC"/br2-external/patches/linux/*.patch; do
		run git -C "$LINUX" apply --check --reverse "$p"
		assert_success "$(basename "$p")"
	done
}
