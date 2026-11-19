# Rootless namespaces for the integration tier. NO TESTS LIVE HERE.

# in_ns <script>: runs the script as root of fresh user, mount and network namespaces, so it
# can mount over the image's paths and bring up interfaces without touching the host.
in_ns() {
	unshare -rmn bash -euc "ip link set lo up; $1"
}
