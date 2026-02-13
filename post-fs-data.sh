#!/system/bin/sh

LOGDIR=/data/adb/networkengine

mkdir -p "$LOGDIR"
chmod 755 "$LOGDIR"

if [ ! -f "$LOGDIR/original_cc" ]; then
  cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null > "$LOGDIR/original_cc"
fi

if [ ! -f "$LOGDIR/original_qdisc" ]; then
  cat /proc/sys/net/core/default_qdisc 2>/dev/null > "$LOGDIR/original_qdisc"
fi

echo 1 > /proc/sys/net/ipv4/tcp_sack 2>/dev/null
echo 1 > /proc/sys/net/ipv4/tcp_window_scaling 2>/dev/null
echo 1 > /proc/sys/net/ipv4/tcp_mtu_probing 2>/dev/null
