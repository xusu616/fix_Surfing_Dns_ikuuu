#!/system/bin/sh
# Uninstall cleanup & precision configuration restore

_self_dir=$(dirname "$0" 2>/dev/null || echo ".")
MODDIR=$(CDPATH= cd -- "$_self_dir" && pwd)

if [ -f "${MODDIR}/common/dns_lib.sh" ] && [ -f "${MODDIR}/common/agh_fix.sh" ]; then
  . "${MODDIR}/common/dns_lib.sh"
  init_env
  stop_module_inotifyd "$MODDIR"
  if restore_precision_backup "uninstall"; then
    rm -rf "$DATA_DIR"
  else
    log_msg "Uninstall restore failed; preserving ${DATA_DIR} for manual recovery"
  fi
else
  if command -v pkill >/dev/null 2>&1; then
    pkill -f "fix_Surfing_Dns_ikuuu/common/inotify.sh" >/dev/null 2>&1 || true
  fi
  printf '%s\n' "[!] 恢复库缺失，保留 /data/adb/fix_Surfing_Dns_ikuuu 的备份供手动恢复。"
fi
