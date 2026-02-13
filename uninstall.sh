#!/system/bin/sh

LOGDIR=/data/adb/networkengine
LOGFILE=$LOGDIR/debug.log

log() {
  echo "[$(date '+%H:%M:%S')] $1" >> "$LOGFILE"
}

AVAILABLE_CC=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)

log "Network Engine Uninstall Started"

# Restore Congestion Control
if [ -f "$LOGDIR/original_cc" ]; then
  RESTORE_CC=$(cat "$LOGDIR/original_cc")
elif echo "$AVAILABLE_CC" | grep -qw cubic; then
  RESTORE_CC=cubic
else
  RESTORE_CC=reno
fi

# Restore Qdisc
if [ -f "$LOGDIR/original_qdisc" ]; then
  RESTORE_QDISC=$(cat "$LOGDIR/original_qdisc")
else
  RESTORE_QDISC=pfifo_fast
fi

echo "$RESTORE_CC" > /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null
echo "$RESTORE_QDISC" > /proc/sys/net/core/default_qdisc 2>/dev/null

for IFACE in $(ip -o link show | awk -F': ' '{print $2}'); do
  if echo "$IFACE" | grep -qE "wlan|rmnet|ccmni|usb"; then
    tc qdisc replace dev "$IFACE" root "$RESTORE_QDISC" 2>/dev/null
  fi
done

log "Restored CC: $RESTORE_CC"
log "Restored Qdisc: $RESTORE_QDISC"
log "Network Engine removed"

rm -rf "$LOGDIR"
