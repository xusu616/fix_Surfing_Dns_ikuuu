#!/system/bin/sh
# Manual diagnostic & self-repair script for KernelSU / APatch / Magisk Action button
# Based on https://github.com/xusu616/ikuuudnstester

_self_dir=$(dirname "$0" 2>/dev/null || echo ".")
MODDIR=$(CDPATH= cd -- "$_self_dir" && pwd)
[ -f "${MODDIR}/common/dns_lib.sh" ] || { echo "[ FAIL ] 缺失 common/dns_lib.sh"; exit 1; }
. "${MODDIR}/common/dns_lib.sh"
init_env

USE_COLOR=0
if [ -t 1 ] && [ "$KSU" != "true" ] && [ "$APATCH" != "true" ] && [ -z "$MAGISK_VER_CODE" ]; then
  USE_COLOR=1
fi

if [ "$USE_COLOR" -eq 1 ]; then
  CLR_RED="\033[1;31m"
  CLR_GRN="\033[1;32m"
  CLR_YLW="\033[1;33m"
  CLR_CYN="\033[1;36m"
  CLR_BLD="\033[1m"
  CLR_RST="\033[0m"
else
  CLR_RED=""; CLR_GRN=""; CLR_YLW=""; CLR_CYN=""; CLR_BLD=""; CLR_RST=""
fi

pass() { printf "  [${CLR_GRN} PASS ${CLR_RST}] %s\n" "$*"; }
fail() { printf "  [${CLR_RED} FAIL ${CLR_RST}] %s\n" "$*"; }
warn() { printf "  [${CLR_YLW} WARN ${CLR_RST}] %s\n" "$*"; }
info() { printf "  [${CLR_CYN} INFO ${CLR_RST}] %s\n" "$*"; }

# Ensure real-time watcher is alive if module is live and enabled
if [ "$MODDIR" = "$LIVE_MOD_DIR" ] && [ ! -f "${MODDIR}/disable" ] && [ ! -f "${MODDIR}/remove" ]; then
  if [ -n "$PGREP" ]; then
    $PGREP -f "inotifyd ${MODDIR}/common/inotify.sh" >/dev/null 2>&1 || start_module_inotifyd "$MODDIR"
  fi
fi

printf "${CLR_BLD}======================================================${CLR_RST}\n"
printf "${CLR_BLD}     Fix Surfing DNS (ikuuu) 实时诊断与修复自检${CLR_RST}\n"
printf "${CLR_BLD}======================================================${CLR_RST}\n"
echo "测试时间: $(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
echo "当前策略: 写入=${DNS_WRITE_MODE} | 模式=${REPLACE_MODE} | CN_IP_no-resolve=${ADD_CN_IP_NORESOLVE} | 开机同步=${AUTO_BOOT_SYNC}"
echo ""

check_cn_ip_missing_noresolve() {
  $AWK '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    /^[[:space:]]*-[[:space:]]*["'\'']?RULE-SET,CN_IP,/ {
      has_any = 1;
      cpos = match($0, /[[:space:]]+#/);
      body = (cpos > 0) ? substr($0, 1, cpos - 1) : $0;
      sub(/[[:space:]]+$/, "", body);
      if (body !~ /,no-resolve["'\'']?$/) { missing = 1; exit }
    }
    END {
      if (!has_any) print 0;
      else if (missing) print 2;
      else print 1;
    }
  ' "$CLASH_CONFIG" 2>/dev/null
}

# ------------------------------------------------------------------------------
# 1. 检查 Clash 主配置 (proxy-server-nameserver) 与 CN_IP 状态
# ------------------------------------------------------------------------------
printf "${CLR_BLD}[1/5] 检查 Clash 主配置 (proxy-server-nameserver & CN_IP)...${CLR_RST}\n"
CURRENT_PSN=""
_cnip_state=0
if [ -f "$CLASH_CONFIG" ]; then
  CURRENT_PSN=$(get_active_psn_entries "$CLASH_CONFIG")
  if [ -n "$CURRENT_PSN" ]; then
    _first_psn=$(printf '%s\n' "$CURRENT_PSN" | head -n 1)
    pass "当前生效的首条节点入口 DNS: ${_first_psn}"
  else
    fail "未在 ${CLASH_CONFIG} 的 dns.proxy-server-nameserver 中找到有效条目！"
  fi

  _cnip_state=$(check_cn_ip_missing_noresolve)
  if [ "${_cnip_state:-0}" -eq 2 ]; then
    warn "CN_IP 规则尚未完整携带 ,no-resolve"
  elif [ "${_cnip_state:-0}" -eq 1 ]; then
    pass "RULE-SET,CN_IP 已包含 ,no-resolve"
  fi

  if [ -f "$BACKUP_PSN_META" ]; then
    info "精准块备份已就绪 (禁用或卸载模块将精准还原)"
  elif [ -f "$BACKUP_FULL" ]; then
    info "模块处于未启用/已还原状态 (原始全量备份留存中)"
  fi
else
  fail "找不到 Clash 主配置文件: ${CLASH_CONFIG}"
fi

# ------------------------------------------------------------------------------
# 2. 从订阅提取官方抗污染 DNS，检测一致并在漂移时自动修复
# ------------------------------------------------------------------------------
echo ""
printf "${CLR_BLD}[2/5] 检查订阅文件官方 DNS 规则与一致性...${CLR_RST}\n"
SUB_DNS_LIST=$(extract_sub_dns_entries)
TARGET_IP=""
DNS_PORT="8080"

if [ -n "$SUB_DNS_LIST" ]; then
  OFFICIAL_DNS_URL=$(printf '%s\n' "$SUB_DNS_LIST" | head -n 1)
  pass "订阅中官方抗污染 DNS: ${OFFICIAL_DNS_URL}"

  _hp="${OFFICIAL_DNS_URL#tcp://}"
  DNS_HOST="${_hp%%:*}"
  DNS_PORT="${_hp##*:}"
  [ -z "$DNS_PORT" ] && DNS_PORT="8080"

  _offline_cached_ip=0
  if is_valid_ipv4 "$DNS_HOST"; then
    TARGET_IP="$DNS_HOST"
  else
    DNS_RESOLVED_IP=$(resolve_host_to_ip "$DNS_HOST")
    if [ -n "$DNS_RESOLVED_IP" ]; then
      info "官方域名实时解析公网 IP: ${DNS_RESOLVED_IP}:${DNS_PORT}"
      TARGET_IP="$DNS_RESOLVED_IP"
    else
      warn "当前无法解析域名 ${DNS_HOST}（请检查网络），仅按现有配置校验"
      TARGET_IP="$DNS_HOST"
    fi
  fi

  # Determine expected DNS list and detect drift
  if build_target_dns_entries; then
    _need_repair=0
    _first_psn=$(printf '%s\n' "$CURRENT_PSN" | head -n 1)

    if [ "$DNS_WRITE_MODE" = "ip" ] && [ "$USED_DOMAIN_FALLBACK" = "1" ]; then
      # If offline/unresolvable while an existing valid public IPv4 is already set, don't overwrite it with domain fallback
      _cur_host="${_first_psn#tcp://}"
      _cur_host="${_cur_host%%:*}"
      if is_usable_public_ipv4 "$_cur_host"; then
        _offline_cached_ip=1
        TARGET_IP="$_cur_host"
      fi
    fi

    if [ "$_offline_cached_ip" -eq 0 ]; then
      while IFS= read -r _exp; do
        [ -z "$_exp" ] && continue
        if ! printf '%s\n' "$CURRENT_PSN" | grep -qxF -- "$_exp"; then
          _need_repair=1
          break
        fi
      done <<EOF
$TARGET_DNS_LIST
EOF
    fi

    if [ "$ADD_CN_IP_NORESOLVE" = "1" ] && [ "${_cnip_state:-0}" -eq 2 ]; then
      _need_repair=1
    fi

    if [ "$_need_repair" -eq 0 ]; then
      pass "当前生效配置与订阅/优化策略一致！"
    else
      warn "检测到配置漂移（当前首条: ${_first_psn:-空}）！"
      if [ ! -f "${MODDIR}/disable" ] && [ ! -f "${MODDIR}/remove" ]; then
        info "模块处于启用状态，尝试自动同步修复并校验..."
        if apply_dns_fix "action_repair"; then
          CURRENT_PSN=$(get_active_psn_entries "$CLASH_CONFIG")
          pass "已自动重应用并修复完成！"
        else
          fail "自动修复失败，已回滚保障原有配置安全！"
        fi
      fi
    fi
  fi
else
  warn "未在 ${PROXIES_DIR}/*.yaml|yml 找到 nameserver-policy tcp:// 规则"
fi

# ------------------------------------------------------------------------------
# 3. 检查 AdGuardHome 规则拦截与 127.0.0.1 本地端口防冲突状态
# ------------------------------------------------------------------------------
echo ""
printf "${CLR_BLD}[3/5] 检查 AdGuardHome 规则保护与 127.0.0.1 兼容性...${CLR_RST}\n"
AGH_PROXY_SH="/data/adb/agh/scripts/ProxyConfig.sh"
AGH_CONF="/data/adb/agh/settings.conf"
_agh_found=0

if [ -f "$AGH_PROXY_SH" ]; then
  _agh_found=1
  if grep "ALL_SECTIONS" "$AGH_PROXY_SH" 2>/dev/null | grep -q "proxy-server-nameserver"; then
    fail "检测到旧版 AGH ProxyConfig.sh 包含 proxy-server-nameserver，可能会覆盖机场 DNS！"
  else
    pass "AGH ProxyConfig.sh 已豁免 proxy-server-nameserver。"
  fi
fi

if [ -f "$AGH_CONF" ]; then
  _agh_found=1
  _agh_ipt=$(sed -n 's/^[[:space:]]*enable_iptables=["'\'']\{0,1\}\([^"'\''[:space:]#]*\).*/\1/p' "$AGH_CONF" 2>/dev/null | head -n 1)
  _agh_port=$(sed -n 's/^[[:space:]]*redir_port=["'\'']\{0,1\}\([^"'\''[:space:]#]*\).*/\1/p' "$AGH_CONF" 2>/dev/null | head -n 1)
  if [ "$_agh_ipt" = "true" ]; then
    warn "AGH settings.conf 中 enable_iptables=true，可能会与 Clash Fake-IP 抢占 53 端口。"
  else
    pass "twoone3 版 AGH 协同正常 (enable_iptables=${_agh_ipt:-false}, port=${_agh_port:-unset})。"
  fi
fi

if [ -f "$CLASH_CONFIG" ]; then
  if printf '%s\n' "$CURRENT_PSN" | grep -Eq '(^|://)127\.0\.0\.1(:|$)'; then
    warn "proxy-server-nameserver 中存在 127.0.0.1，可能会使代理入口解析被 AGH 劫持或回环！"
  else
    _agh_dns_local=$($AWK '
      BEGIN { in_dns=0; in_sub=0 }
      /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
      /^[^[:space:]#]/ { in_dns = ($0 ~ /^dns:[[:space:]]*(#.*)?$/); in_sub=0; next }
      in_dns {
        if ($0 ~ /^[[:space:]]*(nameserver-policy|nameserver|direct-nameserver|fallback):/) { in_sub=1; next }
        if ($0 ~ /^[[:space:]]*proxy-server-nameserver:/) { in_sub=0; next }
        if ($0 ~ /^[[:space:]]{1,4}[A-Za-z0-9_-]+:/) { in_sub=0; next }
        if (in_sub && $0 ~ /127\.0\.0\.1:[0-9]+/) { found=1; exit }
      }
      END { print found + 0 }
    ' "$CLASH_CONFIG" 2>/dev/null)
    if [ "${_agh_dns_local:-0}" -eq 1 ]; then
      pass "检测到 DNS 配置中的本地 127.0.0.1 AGH 端口保留完好，本模块未干扰。"
      _agh_found=1
    fi
  fi
fi

[ "$_agh_found" -eq 0 ] && info "当前未安装 AdGuardHome，兼容检查正常。"

# ------------------------------------------------------------------------------
# 4. 测试抗污染专用 DNS（实际解析 & TCP 端口）可用性
# ------------------------------------------------------------------------------
echo ""
if [ -n "$TARGET_IP" ]; then
  printf "${CLR_BLD}[4/5] 测试抗污染 DNS (${TARGET_IP}:${DNS_PORT}) 连通性与解析能力...${CLR_RST}\n"
  ENTRY_DOMAIN=$(extract_test_entry_domain)
  [ -z "$ENTRY_DOMAIN" ] && ENTRY_DOMAIN="example.com"
  info "测试节点入口域名: ${ENTRY_DOMAIN}"

  _probe_target="$TARGET_IP"
  if ! is_valid_ipv4 "$_probe_target"; then
    _probe_target=$(resolve_host_to_ip "$_probe_target" || true)
  fi

  RESOLVED_IP=""
  if [ -n "$_probe_target" ]; then
    for _try in 1 2 3; do
      _res=$(run_nslookup_timeout 4 "$CAN_SETUIDGID" "$ENTRY_DOMAIN" "${_probe_target}:${DNS_PORT}")
      RESOLVED_IP=$(printf '%s\n' "$_res" | parse_nslookup_ipv4 | pick_first_usable_ipv4)
      [ -n "$RESOLVED_IP" ] && break
      sleep 1
    done
  fi

  _tcp_ok=0
  if [ -z "$RESOLVED_IP" ] && [ -n "$_probe_target" ]; then
    probe_dns_tcp_wire "$_probe_target" "$DNS_PORT" && _tcp_ok=1
  fi

  if [ -n "$RESOLVED_IP" ]; then
    pass "专用 DNS 响应正常！将入口解析为: ${RESOLVED_IP}"
  elif [ "$_tcp_ok" -eq 1 ]; then
    pass "专用 DNS-over-TCP (${_probe_target}:${DNS_PORT}) 协议响应正常！"
  else
    fail "专用 DNS (${TARGET_IP}:${DNS_PORT}) 解析超时或无返回！"
  fi
else
  printf "${CLR_BLD}[4/5] 测试抗污染 DNS 连通性...${CLR_RST}\n"
  warn "未提取到目标抗污染 DNS，跳过直连探测。"
fi

# ------------------------------------------------------------------------------
# 5. Clash 核心配置合法性 & IEPL 节点实时连通延迟测试
# ------------------------------------------------------------------------------
echo ""
printf "${CLR_BLD}[5/5] 校验 Clash 核心配置并测试代理节点可用性...${CLR_RST}\n"
if [ -n "$BOX_BIN" ] && [ -f "$CLASH_CONFIG" ]; then
  if "$BOX_BIN" -t -d "$CLASH_DIR" -f "$CLASH_CONFIG" >/dev/null 2>&1; then
    pass "Clash 核心语法与规则集校验通过 (-t)"
  else
    fail "Clash 核心配置校验失败 (-t)，请检查 config.yaml！"
  fi
fi

if [ -n "$CURL" ] && [ -f "$CLASH_CONFIG" ]; then
  parse_controller_info
  _base_api="http://${API_HOST}:${API_PORT}"
  _auth_hdr=""
  [ -n "$API_SECRET" ] && _auth_hdr="Authorization: Bearer ${API_SECRET}"

  _api_get() {
    if [ -n "$_auth_hdr" ]; then
      "$CURL" -s --max-time 5 -H "$_auth_hdr" "${_base_api}$1" 2>/dev/null
    else
      "$CURL" -s --max-time 5 "${_base_api}$1" 2>/dev/null
    fi
  }

  DELAY_TEST=$(_api_get "/proxies/ALL%C2%B7%E9%A6%99%E6%B8%AF%E5%9C%B0%E5%8C%BA/delay?timeout=4000&url=https://www.gstatic.com/generate_204")
  if echo "$DELAY_TEST" | grep -q '"delay"'; then
    DELAY_MS=$(echo "$DELAY_TEST" | grep -o -E '"delay":[0-9]+' | cut -d: -f2)
    pass "香港 IEPL 专线实测连通成功！延迟: ${DELAY_MS} ms"
  else
    CURRENT_NODE=$(_api_get "/proxies/GLOBAL" | grep -o '"now":"[^"]*"' | cut -d'"' -f4)
    if [ -n "$CURRENT_NODE" ]; then
      info "当前 GLOBAL 模式选中节点: ${CURRENT_NODE}"
      _enc_node=$(printf '%s' "$CURRENT_NODE" | $AWK '
        BEGIN {
          for (i = 0; i < 256; i++) ord[sprintf("%c", i)] = i;
        }
        {
          out = "";
          for (i = 1; i <= length($0); i++) {
            c = substr($0, i, 1);
            if (c ~ /[A-Za-z0-9._~-]/) out = out c;
            else out = out sprintf("%%%02X", ord[c]);
          }
          print out;
        }
      ')
      if [ -n "$_enc_node" ]; then
        _node_delay=$(_api_get "/proxies/${_enc_node}/delay?timeout=4000&url=https://www.gstatic.com/generate_204")
        if echo "$_node_delay" | grep -q '"delay"'; then
          DELAY_MS=$(echo "$_node_delay" | grep -o -E '"delay":[0-9]+' | cut -d: -f2)
          pass "当前节点 (${CURRENT_NODE}) 实测连通成功！延迟: ${DELAY_MS} ms"
        fi
      fi
    else
      warn "未能连接 Clash 控制接口 (${API_HOST}:${API_PORT})，可能 Clash 未启动或处于禁用状态"
    fi
  fi
fi

if [ -f "${MODDIR}/disable" ] || [ -f "${MODDIR}/remove" ]; then
  update_module_desc "$MODDIR" "disabled"
else
  update_module_desc "$MODDIR" "active"
fi

echo ""
printf "${CLR_BLD}======================================================${CLR_RST}\n"
printf "${CLR_BLD}                 诊断与自检完成${CLR_RST}\n"
printf "${CLR_BLD}======================================================${CLR_RST}\n"
