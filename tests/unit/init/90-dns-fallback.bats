# dhcpcd hook: public resolvers when a lease brought none, never over one it brought.
load ../../support/common

setup() {
	sf_setup
	export RESOLV_CONF="$T/resolv.conf"
	HOOK="$OVERLAY/lib/dhcpcd/dhcpcd-hooks/90-dns-fallback"
}

hook() { reason="$1" sh -c ". '$HOOK'"; }

@test "a lease without DNS gets the fallbacks" {
	: > "$RESOLV_CONF"
	hook BOUND
	assert_equal "$(cat "$RESOLV_CONF")" "nameserver 1.1.1.1
nameserver 8.8.8.8"
}

@test "DNS from the lease is kept" {
	echo 'nameserver 10.0.2.3' > "$RESOLV_CONF"
	hook RENEW
	assert_equal "$(cat "$RESOLV_CONF")" 'nameserver 10.0.2.3'
}

@test "other events leave resolv.conf alone" {
	: > "$RESOLV_CONF"
	hook EXPIRE
	assert_equal "$(cat "$RESOLV_CONF")" ''
}
