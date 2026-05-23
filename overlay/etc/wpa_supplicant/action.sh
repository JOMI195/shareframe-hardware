#!/bin/sh
IFACE="$1"
EVENT="$2"
[ "$IFACE" = "wlan0" ] || exit 0
PID=$(pidof udhcpc) || exit 0
case "$EVENT" in
    CONNECTED)    kill -USR1 $PID ;;
    DISCONNECTED) kill -USR2 $PID ;;
esac
