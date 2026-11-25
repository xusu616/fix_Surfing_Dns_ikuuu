#!/system/bin/sh
# Installer script for fix_Surfing_Dns_ikuuu (Magisk / KernelSU / APatch)

command -v ui_print >/dev/null 2>&1 || ui_print() { printf '%s\n' "$1"; }
command -v abort >/dev/null 2>&1 || abort() { ui_print "$1"; exit 1; }
command -v set_perm >/dev/null 2>&1 || set_perm() {
  chown "$2:$3" "$1" 2>/dev/null || true
  chmod "$4" "$1" 2>/dev/null || true
}
command -v set_perm_recursive >/dev/null 2>&1 || set_perm_recursive() {
  find "$1" -type d -exec chown "$2:$3" {} + -exec chmod "$4" {} + 2>/dev/null || true
  find "$1" -type f -exec chown "$2:$3" {} + -exec chmod "$5" {} + 2>/dev/null || true
}

if [ -z "$MODPATH" ]; then
  _self_dir=$(dirname "$0" 2>/dev/null || echo ".")
  MODPATH=$(CDPATH= cd -- "$_self_dir" && pwd)
fi

. "${MODPATH}/common/dns_lib.sh"
init_env

_is_upgrade=0
if [ -d "$LIVE_MOD_DIR" ] || [ -f "$SETTINGS_FILE" ] || [ -f "$BACKUP_FULL" ]; then
  _is_upgrade=1
fi

TMP_EV="${DATA_DIR}/.vol_events.$$.tmp"
VOL_DEVS=""
GE_PIDS=""

cleanup_vol_listeners() {
  if [ -n "$GE_PIDS" ]; then
    local _gp=""
    for _gp in $GE_PIDS; do
      kill -9 "$_gp" 2>/dev/null || true
      wait "$_gp" 2>/dev/null || true
    done
    GE_PIDS=""
  fi
  rm -f "$TMP_EV"
}
trap cleanup_vol_listeners EXIT INT TERM

detect_vol_devices() {
  VOL_DEVS=""
  local _cur="" _line=""
  while IFS= read -r _line; do
    case "$_line" in
      "add device "*)
        _cur="${_line#*: }"
        _cur="${_cur%% *}"
        ;;
      *KEY_VOLUMEUP*|*KEY_VOLUMEDOWN*)
        if [ -n "$_cur" ] && [ -e "$_cur" ]; then
          case " $VOL_DEVS " in
            *" $_cur "*) ;;
            *) VOL_DEVS="${VOL_DEVS} ${_cur}" ;;
          esac
        fi
        ;;
    esac
  done <<EOF
$(getevent -lp 2>/dev/null)
EOF
}

choose_vol_key() {
  # Args: title, up_label, down_label, default(up|down), timeout_sec
  local _title="$1"
  local _up_txt="$2"
  local _dn_txt="$3"
  local _def="${4:-up}"
  local _timeout="${5:-10}"
  local _dev="" _def_label="" _start_ts=0 _now_ts=0

  [ "$_def" = "up" ] && _def_label="音量+" || _def_label="音量-"

  ui_print ""
  ui_print "----------------------------------------"
  ui_print "$_title"
  ui_print "  [音量+] $_up_txt"
  ui_print "  [音量-] $_dn_txt"
  ui_print "  (${_timeout}秒内无操作自动默认: ${_def_label})"

  if [ -z "$VOL_DEVS" ]; then
    ui_print "  -> 未检测到音量键输入设备，采用默认: ${_def_label}"
    CHOICE="$_def"
    return 0
  fi

  : > "$TMP_EV"
  GE_PIDS=""
  for _dev in $VOL_DEVS; do
    getevent -lq "$_dev" >> "$TMP_EV" 2>/dev/null &
    GE_PIDS="${GE_PIDS} $!"
  done

  _start_ts=$(date +%s 2>/dev/null || echo 0)
  CHOICE=""
  while :; do
    if grep -qE 'KEY_VOLUMEUP[[:space:]]+DOWN' "$TMP_EV" 2>/dev/null; then
      CHOICE="up"
      break
    fi
    if grep -qE 'KEY_VOLUMEDOWN[[:space:]]+DOWN' "$TMP_EV" 2>/dev/null; then
      CHOICE="down"
      break
    fi
    _now_ts=$(date +%s 2>/dev/null || echo 0)
    if [ "$_start_ts" -gt 0 ] && [ "$_now_ts" -gt 0 ]; then
      [ $((_now_ts - _start_ts)) -ge "$_timeout" ] && break
    else
      break
    fi
    short_sleep
  done

  cleanup_vol_listeners

  if [ -z "$CHOICE" ]; then
    CHOICE="$_def"
    ui_print "  -> 等待超时，自动选择默认: ${_def_label}"
  elif [ "$CHOICE" = "up" ]; then
    ui_print "  -> 已选择 [音量+]: $_up_txt"
    short_sleep
  else
    ui_print "  -> 已选择 [音量-]: $_dn_txt"
    short_sleep
  fi
}

ui_print "========================================"
ui_print "  Fix Surfing DNS (ikuuu) 模块安装向导"
ui_print "  Author: suxv616 | Magisk / KSU / APatch"
ui_print "========================================"

if [ ! -f "$CLASH_CONFIG" ]; then
  trap - EXIT INT TERM
  abort "[!] 未找到 Surfing 主配置文件: ${CLASH_CONFIG}，请先安装并初始化 Surfing 模块！"
fi

detect_vol_devices

# 按键选择 1: DNS 写入形式 (IP+兜底 vs 原始域名)
choose_vol_key \
  "[选择 1/5] 写入 proxy-server-nameserver 的 DNS 格式:" \
  "解析为公网 IP 写入 (推荐，解析失败自动兜底原域名)" \
  "直接写入订阅原始域名 (保留 tcp://域名:端口)" \
  "up" 10
[ "$CHOICE" = "up" ] && _sel_write="ip" || _sel_write="domain"

# 按键选择 2: 原有 proxy-server-nameserver 处理方式
choose_vol_key \
  "[选择 2/5] 原有 proxy-server-nameserver 处理方式:" \
  "完全替换为机场抗污染 DNS (清除原 DoH，兼容忽略 127.0.0.1)" \
  "保留原有 DoH 作为备用，将机场抗污染 DNS 置顶" \
  "up" 10
[ "$CHOICE" = "up" ] && _sel_replace="replace" || _sel_replace="prepend"

# 按键选择 3: 额外优化 1 - CN_IP ,no-resolve (独立按键，不合并)
choose_vol_key \
  "[选择 3/5] 额外优化 - CN_IP 分流防泄露:" \
  "自动为 RULE-SET,CN_IP 补上 ,no-resolve (推荐)" \
  "保持 CN_IP 规则原样不动" \
  "up" 10
[ "$CHOICE" = "up" ] && _sel_cnip="1" || _sel_cnip="0"

# 按键选择 4: 额外优化 2 - 触发与同步方式 (独立按键，不合并，默认仅刷入+手动)
choose_vol_key \
  "[选择 4/5] 额外优化 - 后续同步策略:" \
  "仅刷入时修复 + 管理器「操作」按钮手动自检/修复 (推荐)" \
  "开启开机后后台自检同步 (模块/订阅更新后自动重修)" \
  "up" 10
[ "$CHOICE" = "up" ] && _sel_boot="0" || _sel_boot="1"

choose_vol_key \
  "[选择 5/5] AGH + Surfing 联动，修复 DNSPod DoH 直连超时:" \
  "启用（兼容配置下使用 inet + 两条 DNS连接 规则；重启后应用）" \
  "关闭（不接管 AGH；恢复本模块此前拥有的 AGH 改动）" \
  "up" 10
[ "$CHOICE" = "up" ] && _sel_agh="1" || _sel_agh="0"

DNS_WRITE_MODE="$_sel_write"
REPLACE_MODE="$_sel_replace"
ADD_CN_IP_NORESOLVE="$_sel_cnip"
AUTO_BOOT_SYNC="$_sel_boot"
AGH_FIX_ENABLED="$_sel_agh"

if [ "$_is_upgrade" -eq 1 ] && [ -f "${LIVE_MOD_DIR}/disable" ]; then
  save_settings
  update_module_desc "$MODPATH" "pending_reboot"
  ui_print ""
  ui_print "[*] 检测到当前模块处于禁用状态，已更新偏好设置，暂不写入 config.yaml（重新启用时自动应用）。"
else
  ui_print ""
  ui_print "========================================"
  ui_print "  正在备份原配置、写入 DNS 并执行校验..."
  ui_print "========================================"

  if ! apply_dns_fix "install"; then
    ui_print ""
    ui_print "[!] DNS 修复或校验未完成，请查看日志中的回滚结果。"
    ui_print "[!] 详细日志请查看: ${LOG_FILE}"
    # APPLIED=0 does not prove a failed write/reload was rolled back.
    # Only the transaction itself may discard a confirmed-unneeded backup.
    cleanup_vol_listeners
    trap - EXIT INT TERM
    abort "安装已中止；恢复失败时备份和快照会保留，请勿删除模块数据目录。"
  fi

  save_settings
  update_module_desc "$MODPATH" "pending_reboot"
fi

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "${MODPATH}/customize.sh" 0 0 0755
set_perm "${MODPATH}/service.sh" 0 0 0755
set_perm "${MODPATH}/action.sh" 0 0 0755
set_perm "${MODPATH}/uninstall.sh" 0 0 0755
set_perm "${MODPATH}/common/dns_lib.sh" 0 0 0755
set_perm "${MODPATH}/common/agh_fix.sh" 0 0 0755
set_perm "${MODPATH}/common/inotify.sh" 0 0 0755

if [ -d "$LIVE_MOD_DIR" ] && [ -f "${LIVE_MOD_DIR}/common/inotify.sh" ] && [ "$MODPATH" = "$LIVE_MOD_DIR" ]; then
  start_module_inotifyd "$LIVE_MOD_DIR"
fi

cleanup_vol_listeners
trap - EXIT INT TERM

ui_print ""
ui_print "========================================"
ui_print "  安装与校验全部通过！"
ui_print "  - 备份位置: ${BACKUP_DIR}"
ui_print "  - 关闭/卸载模块将实时精准还原原配置"
ui_print "  - 可随时在管理器点击「操作」运行 DNS 自检"
ui_print "  - AGH 联动选项: $AGH_FIX_ENABLED；仅恢复本模块实际拥有的改动"
ui_print "========================================"
