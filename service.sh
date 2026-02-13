#!/system/bin/sh

MODDIR=${0%/*}
LOGDIR=/data/adb/networkengine
LOGFILE=$LOGDIR/debug.log

mkdir -p "$LOGDIR"
sleep 15

log() {
  echo "[$(date '+%H:%M:%S')] $1" >> "$LOGFILE"
}

write_if_lower() {
  CURRENT=$(cat "$1" 2>/dev/null)
  if [ -n "$CURRENT" ] && [ "$CURRENT" -lt "$2" ]; then
    echo "$2" > "$1" 2>/dev/null
  fi
}

write_force() {
  echo "$2" > "$1" 2>/dev/null
}

log "Engine start"

# -----------------------

AVAILABLE_CC=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)

if echo "$AVAILABLE_CC" | grep -qw bbr; then
  BEST_CC=bbr
elif echo "$AVAILABLE_CC" | grep -qw cubic; then
  BEST_CC=cubic
else
  BEST_CC=reno
fi

if grep -q sch_fq /proc/modules 2>/dev/null || \
   zcat /proc/config.gz 2>/dev/null | grep -q CONFIG_NET_SCH_FQ=y; then
  BEST_QDISC=fq
else
  BEST_QDISC=pfifo_fast
fi

write_force /proc/sys/net/ipv4/tcp_congestion_control "$BEST_CC"
write_force /proc/sys/net/core/default_qdisc "$BEST_QDISC"

log "CC:$BEST_CC Qdisc:$BEST_QDISC"

LAST_MODE=""
LAST_METERED=""
LAST_RMEM=""
INIT_APPLIED=0

# -----------------------

apply_stability_layer() {
  write_force /proc/sys/net/ipv4/tcp_sack 1
  write_force /proc/sys/net/ipv4/tcp_window_scaling 1
  write_force /proc/sys/net/ipv4/tcp_tw_reuse 1

  RETRIES=$(cat /proc/sys/net/ipv4/tcp_syn_retries 2>/dev/null)
  [ -n "$RETRIES" ] && [ "$RETRIES" -gt 5 ] && \
    write_force /proc/sys/net/ipv4/tcp_syn_retries 5
}

# -----------------------

apply_init_window() {

  [ "$INIT_APPLIED" -eq 1 ] && return

  DEFAULT_IFACE=$(ip route show default 2>/dev/null | awk '{print $5}')

  [ -z "$DEFAULT_IFACE" ] && return

  ip route change default dev "$DEFAULT_IFACE" initcwnd 16 initrwnd 16 2>/dev/null

  if [ $? -eq 0 ]; then
    log "initcwnd:16 initrwnd:16"
    INIT_APPLIED=1
  fi
}

# -----------------------

apply_profile() {

  DEFAULT_IFACE=$(ip route show default 2>/dev/null | awk '{print $5}')

  case "$DEFAULT_IFACE" in
    wlan*) MODE=wifi ;;
    rmnet*|ccmni*|usb*) MODE=mobile ;;
    *) MODE=mobile ;;
  esac

  dumpsys netpolicy 2>/dev/null | grep -q metered
  [ $? -eq 0 ] && METERED=1 || METERED=0

  SIGNAL=-90

  if [ "$MODE" = "mobile" ]; then
    RAW_SIGNAL=$(dumpsys telephony.registry 2>/dev/null \
      | grep -m1 -E "mSignalStrength|mLteRsrp" \
      | grep -oE "-[0-9]+" | head -n1)
    [ -n "$RAW_SIGNAL" ] && SIGNAL=$RAW_SIGNAL
  fi

  if [ "$MODE" = "wifi" ]; then
    if [ "$METERED" -eq 1 ]; then
      RMEM_MAX=6291456
      WMEM_MAX=6291456
      BACKLOG=8000
    else
      RMEM_MAX=12582912
      WMEM_MAX=12582912
      BACKLOG=15000
    fi
  else
    if [ "$SIGNAL" -lt -110 ]; then
      RMEM_MAX=4194304
      WMEM_MAX=4194304
      BACKLOG=5000
    elif [ "$SIGNAL" -lt -95 ]; then
      RMEM_MAX=6291456
      WMEM_MAX=6291456
      BACKLOG=8000
    else
      RMEM_MAX=10485760
      WMEM_MAX=10485760
      BACKLOG=12000
    fi
  fi

  # Hard safety cap (16MB)
  [ "$RMEM_MAX" -gt 16777216 ] && RMEM_MAX=16777216
  [ "$WMEM_MAX" -gt 16777216 ] && WMEM_MAX=16777216

  write_if_lower /proc/sys/net/core/rmem_max "$RMEM_MAX"
  write_if_lower /proc/sys/net/core/wmem_max "$WMEM_MAX"
  write_if_lower /proc/sys/net/core/netdev_max_backlog "$BACKLOG"

  write_force /proc/sys/net/ipv4/tcp_low_latency 1
  write_force /proc/sys/net/ipv4/tcp_fastopen 1
  write_force /proc/sys/net/ipv4/tcp_mtu_probing 1

  write_force /proc/sys/net/ipv4/tcp_rmem "4096 131072 $RMEM_MAX"
  write_force /proc/sys/net/ipv4/tcp_wmem "4096 131072 $WMEM_MAX"

  apply_stability_layer
  apply_init_window

  if [ "$MODE" != "$LAST_MODE" ] || \
     [ "$METERED" != "$LAST_METERED" ] || \
     [ "$RMEM_MAX" != "$LAST_RMEM" ]; then

      log "Mode:$MODE Metered:$METERED RMEM:$RMEM_MAX"
      LAST_MODE=$MODE
      LAST_METERED=$METERED
      LAST_RMEM=$RMEM_MAX
  fi
}

# -----------------------

apply_qdisc_interfaces() {
  for IFACE in $(ip -o link show | awk -F': ' '{print $2}'); do
    echo "$IFACE" | grep -qE "wlan|rmnet|ccmni|usb" || continue
    tc qdisc replace dev "$IFACE" root "$BEST_QDISC" 2>/dev/null
  done
}

apply_profile
apply_qdisc_interfaces

# -----------------------

while true; do

  CURRENT_CC=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)
  CURRENT_QDISC=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null)

  if [ "$CURRENT_CC" != "$BEST_CC" ]; then
    write_force /proc/sys/net/ipv4/tcp_congestion_control "$BEST_CC"
    log "CC restored"
  fi

  if [ "$CURRENT_QDISC" != "$BEST_QDISC" ]; then
    write_force /proc/sys/net/core/default_qdisc "$BEST_QDISC"
    apply_qdisc_interfaces
    log "Qdisc restored"
  fi

  apply_profile

  sleep 45
done
