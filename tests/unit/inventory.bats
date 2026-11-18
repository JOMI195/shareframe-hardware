# Every script of the image has a unit test, or tests/UNTESTED names the tier that covers it.
load ../support/common

@test "every script is tested or listed in tests/UNTESTED with its tier" {
	cd "$SRC"
	missing=
	for f in $(find br2-external/overlay/usr/bin br2-external/overlay/usr/libexec/s6 br2-external/overlay/lib \
		br2-external/package/shareframe-rauc/files br2-external/package/shareframe-init/skel \
		br2-external/package/shareframe-initramfs/rootfs -type f | sort); do
		head -c2 "$f" | grep -q '#!' || continue
		name="$(basename "$f")"
		[ -n "$(find tests/unit -name "$name.bats")" ] && continue
		grep -rqs -- "/$name\"\|/$name\$\| $name\b" tests/unit --include='*.bats' && continue
		grep -q "^$f " tests/UNTESTED && continue
		missing="$missing $f"
	done
	[ -z "$missing" ] || fail "no test and not in tests/UNTESTED:$missing"
}

@test "tests/UNTESTED lists only scripts that exist, each with a tier" {
	cd "$SRC"
	while read -r path tier _; do
		case "$path" in '#'*|'') continue ;; esac
		[ -f "$path" ] || fail "$path is gone"
		case "$tier" in system|hardware|integration) ;; *) fail "$path: unknown tier '$tier'" ;; esac
	done < tests/UNTESTED
}
