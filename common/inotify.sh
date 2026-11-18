#!/system/bin/sh
# Real-time disable/remove listener triggered by BusyBox inotifyd

EVENT="$1"
MONITOR_DIR="$2"
MONITOR_FILE="$3"

case "$MONITOR_FILE" in
  disable|remove) ;;
  *) exit 0 ;;
esac

_self_dir=$(dirname "$0" 2>/dev/null || echo ".")
MODDIR=$(CDPATH= cd -- "${_self_dir}/.." && pwd)
[ -f "${MODDIR}/common/dns_lib.sh" ] || exit 0
. "${MODDIR}/common/dns_lib.sh"
init_env

acquire_lock || exit 0
trap 'release_lock' EXIT

if [ "$MONITOR_FILE" = "disable" ]; then
  case "$EVENT" in
    *n*)
      log_msg "Event: module disabled, restoring precision backup..."
      restore_precision_backup "disable"
      update_module_desc "$MODDIR" "disabled"
      ;;
    *d*)
      if [ ! -f "${MODDIR}/remove" ]; then
        log_msg "Event: module re-enabled, re-applying DNS fix..."
        apply_dns_fix "enable" >/dev/null 2>&1 || true
        update_module_desc "$MODDIR" "active"
      fi
      ;;
  esac
elif [ "$MONITOR_FILE" = "remove" ]; then
  case "$EVENT" in
    *n*)
      log_msg "Event: module marked for removal, restoring precision backup..."
      restore_precision_backup "remove_mark"
      update_module_desc "$MODDIR" "disabled"
      ;;
    *d*)
      if [ ! -f "${MODDIR}/disable" ]; then
        log_msg "Event: module removal cancelled, re-applying DNS fix..."
        apply_dns_fix "remove_cancel" >/dev/null 2>&1 || true
        update_module_desc "$MODDIR" "active"
      fi
      ;;
  esac
fi

exit 0
