# The USB link: setup-usb0's addresses and the image's udhcpd config hand the plugged-in
# computer 10.55.0.2, with neither a gateway nor DNS that would black-hole it.
load ../support/common
load ../support/ns

setup() {
	host_setup
	cp "$OVERLAY/etc/udhcpd.conf" "$T/udhcpd.conf"
	printf '#!/bin/sh\n[ "$1" = bound ] && env | grep -E "^(ip|subnet|router|dns)=" | sort > "%s/lease"\nexit 0\n' "$T" > "$T/udhcpc.sh"
	chmod +x "$T/udhcpc.sh"
}

@test "the computer on the cable gets 10.55.0.2, no router, no DNS" {
	run in_ns "
		mount -t tmpfs run /run && mkdir -p /run/netns
		ip netns add computer
		ip link add usb0 type veth peer name eth0 netns computer
		mkdir -p '$T/sys/class/net/usb0'
		SYSFS='$T/sys' CPUINFO='$SRC/tests/support/fixtures/cpuinfo-pi0w' SF_LIB='$SF_LIB' sh '$S6/setup-usb0'
		ip -4 -o addr show usb0 | awk '{print \"board \" \$4}'
		touch /run/udhcpd.leases
		/opt/busybox/bin/udhcpd -f '$T/udhcpd.conf' >/dev/null 2>&1 & dp=\$!
		nsenter --net=/run/netns/computer ip link set lo up
		nsenter --net=/run/netns/computer ip link set eth0 up
		nsenter --net=/run/netns/computer /opt/busybox/bin/udhcpc -i eth0 -q -n -t 5 -T 1 -s '$T/udhcpc.sh' >/dev/null 2>&1 || echo 'no lease'
		kill \$dp
	" 3>&-
	assert_line 'board 10.55.0.1/24'
	assert_line 'board 169.254.195.212/16'
	refute_line 'no lease'
	assert_equal "$(cat "$T/lease")" 'ip=10.55.0.2
subnet=255.255.255.0'
}
