#!/system/bin/sh
# Optional AGH DNSPod routing fix. Ownership is recorded only for our changes.

init_agh_env() {
  AGH_SETTINGS="/data/adb/agh/settings.conf"
  AGH_YAML="/data/adb/agh/bin/AdGuardHome.yaml"
  AGH_TOOL="/data/adb/agh/scripts/tool.sh"
  AGH_GROUP_BACKUP="$BACKUP_DIR/agh_group.orig"
  AGH_RULES_ADDED="$BACKUP_DIR/agh_rules.added"
}

# Read literal module settings without sourcing another module's shell code.
agh_setting_value() {
  local file="$1" key="$2"
  $AWK -v key="$key" '
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      count++; value=$0;
      sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "", value);
      sub(/[[:space:]]+#.*$/, "", value);
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value);
      if (value ~ /^"[^"]*"$/ || value ~ /^\047[^\047]*\047$/)
        value=substr(value, 2, length(value)-2);
      if (value !~ /^[A-Za-z0-9_.:\/-]+$/) bad=1;
    }
    END { if (count != 1 || bad) exit 1; print value; }
  ' "$file"
}

agh_write_group() {
  local file="$1" value="$2" output="$3"
  agh_setting_value "$file" adg_group >/dev/null || return 1
  case "$value" in inet|net_admin|3003|3005) ;; *) return 1 ;; esac
  $AWK -v value="$value" '
    /^[[:space:]]*adg_group[[:space:]]*=/ { print "adg_group=" value; next }
    { print }
  ' "$file" > "$output"
}

agh_restore_group() {
  local file="$1" backup="$2" output="$3" current="" original=""
  current=$(agh_setting_value "$file" adg_group) || return 1
  original=$(agh_setting_value "$backup" adg_group) || return 1
  case "$original:$current" in
    net_admin:3005|3005:net_admin|inet:3003|3003:inet)
      cp -f "$file" "$output"; return $? ;;
  esac
  if [ "$current" = "$original" ]; then
    cp -f "$file" "$output"
    return $?
  fi
  case "$current" in
    inet|3003) ;;
    *) [ "$current" = "$original" ] || return 1 ;;
  esac
  $AWK -v backup="$backup" '
    BEGIN { if ((getline original < backup) <= 0) exit 1; close(backup); }
    /^[[:space:]]*adg_group[[:space:]]*=/ { print original; next }
    { print }
  ' "$file" > "$output"
}

# Limit this fix to the verified IP-based HTTPS upstream layout. Hostname
# bootstrap would otherwise be caught by Surfing and query AGH recursively.
agh_upstreams_compatible() {
  $AWK '
    function ipv4(host, a,n,i) {
      n=split(host,a,".");
      if(n!=4) return 0;
      for(i=1;i<=4;i++) if(a[i] !~ /^[0-9]+$/ || a[i]+0>255) return 0;
      return 1;
    }
    function value(s) {
      sub(/[[:space:]]+#.*$/, "", s);
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", s);
      if(s ~ /^"[^"]*"$/ || s ~ /^\047[^\047]*\047$/)
        s=substr(s,2,length(s)-2);
      return s;
    }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    /^[^[:space:]]/ { dns=($0 ~ /^dns:[[:space:]]*(#.*)?$/); section=""; client_upstreams=0; next }
    !dns {
      match($0,/^[[:space:]]*/); indent=RLENGTH;
      line=substr($0,indent+1);
      if(line ~ /^upstreams:/) {
        rest=line; sub(/^[^:]+:[[:space:]]*/, "", rest); rest=value(rest);
        if(rest!="" && rest!="[]") bad=1;
        client_upstreams=(rest==""); client_base=indent;
      } else if(client_upstreams) {
        if(indent>=client_base && line ~ /^-/) bad=1;
        if(indent<=client_base) client_upstreams=0;
      }
      next;
    }
    {
      match($0,/^[[:space:]]*/); indent=RLENGTH;
      line=substr($0,indent+1);
      if(line ~ /^(upstream_dns|fallback_dns):/) {
        section=line; sub(/:.*/, "", section); base=indent;
        rest=line; sub(/^[^:]+:[[:space:]]*/, "", rest); rest=value(rest);
        if(rest!="" && rest!="[]") bad=1;
        next;
      }
      if(line ~ /^upstream_dns_file:/) {
        rest=line; sub(/^[^:]+:[[:space:]]*/, "", rest);
        if(value(rest)!="") bad=1;
      }
      if(section!="" && indent>=base && line ~ /^-[[:space:]]+/) {
        sub(/^-[[:space:]]+/, "", line); url=value(line);
        host=url; sub(/^https:\/\//,"",host); sub(/\/.*$/,"",host);
        sub(/:443$/,"",host);
        if(url !~ /^https:\/\/[0-9.]+(:443)?\/dns-query$/ || !ipv4(host)) bad=1;
        if(section=="upstream_dns") {
          count++;
          if(host=="1.12.12.12" || host=="120.53.53.53") dnspod=1;
        }
        next;
      }
      if(section!="" && indent<=base) section="";
    }
    END { if(bad || count==0 || !dnspod) exit 1; }
  ' "$1"
}

agh_rules_ready() {
  $AWK '
    /^rules:[[:space:]]*(#.*)?$/ { rules=1; next }
    rules && /^[^[:space:]#-]/ { rules=0 }
    rules && /^[[:space:]]*-[[:space:]]+/ {
      if(++count>2) next;
      line=$0; sub(/^[[:space:]]*-[[:space:]]+/,"",line);
      sub(/[[:space:]]+#.*$/,"",line);
      gsub(/[[:space:]]/,"",line);
      gsub(/^["\047]|["\047]$/,"",line);
      if(line=="IP-CIDR,1.12.12.12/32,DNS连接,no-resolve") a=1;
      if(line=="IP-CIDR,120.53.53.53/32,DNS连接,no-resolve") b=1;
    }
    END { if(!a || !b) exit 1; }
  ' "$1"
}

# Remove one exact occurrence of each owned line, never every matching rule.
agh_remove_rules() {
  local file="$1" record="$2" output="$3"
  if [ ! -s "$record" ]; then cp -f "$file" "$output"; return $?; fi
  $AWK -v record="$record" '
    BEGIN {
      while((getline line < record)>0) owned[line]++;
      close(record);
    }
    owned[$0]>0 { owned[$0]--; next }
    { print }
  ' "$file" > "$output"
}

agh_rules_conflict() {
  [ -s "$2" ] || return 1
  $AWK -v record="$2" '
    BEGIN {
      while((getline line < record)>0) known[line]=1;
      close(record);
    }
    index($0,"# fix_Surfing_Dns_ikuuu: agh-doh") && !($0 in known) { conflict=1 }
    END { if(!conflict) exit 1; }
  ' "$1"
}

agh_build_rules() {
  local file="$1" output="$2" record="$3" base="$DATA_DIR/agh_rules_base.$$.tmp"
  if agh_rules_ready "$file"; then
    cp -f "$file" "$output" || return 1
    if [ -f "$AGH_RULES_ADDED" ]; then
      cp -f "$AGH_RULES_ADDED" "$record"
    else
      : > "$record"
    fi
    return $?
  fi
  agh_remove_rules "$file" "$AGH_RULES_ADDED" "$base" || return 1
  : > "$record"
  $AWK -v record="$record" '
    function normalize(line) {
      sub(/^[[:space:]]*-[[:space:]]+/,"",line);
      sub(/[[:space:]]+#.*$/,"",line);
      gsub(/[[:space:]]/,"",line);
      gsub(/^["\047]|["\047]$/,"",line);
      return line;
    }
    FNR==NR {
      if($0 ~ /^rules:[[:space:]]*(#.*)?$/) scan=1;
      else if(scan && $0 ~ /^[^[:space:]#-]/) scan=0;
      else if(scan && first=="" && $0 ~ /^[[:space:]]*-[[:space:]]+/)
        first=normalize($0);
      next;
    }
    /^rules:[[:space:]]*(#.*)?$/ {
      count++; print;
      if(first!="IP-CIDR,1.12.12.12/32,DNS连接,no-resolve") {
        line="  - IP-CIDR,1.12.12.12/32,DNS连接,no-resolve # fix_Surfing_Dns_ikuuu: agh-doh";
        print line; print line >> record;
      }
      if(first!="IP-CIDR,120.53.53.53/32,DNS连接,no-resolve") {
        line="  - IP-CIDR,120.53.53.53/32,DNS连接,no-resolve # fix_Surfing_Dns_ikuuu: agh-doh";
        print line; print line >> record;
      }
      next;
    }
    { print }
    END { if(count!=1) exit 1; }
  ' "$base" "$base" > "$output"
  local result=$?
  rm -f "$base"
  [ "$result" -eq 0 ] || return 1
  return 0
}

agh_pid() {
  local pids=""
  pids=$(pidof AdGuardHome 2>/dev/null) || return 1
  set -- $pids
  [ "$#" -gt 0 ] || return 1
  [ "$#" -eq 1 ] || return 2
  printf '%s\n' "$1"
}

agh_pid_gid() {
  $AWK '/^Gid:/ { print $2; exit }' "/proc/$1/status"
}

agh_pid_uid() {
  $AWK '/^Uid:/ { print $2; exit }' "/proc/$1/status"
}

agh_restart_running() {
  # Never start a resolver that the user had stopped.
  [ "$1" = 1 ] || return 0
  local expected="$2" pid="" waited=0
  "$AGH_TOOL" stop >> "$LOG_FILE" 2>&1 || return 1
  "$AGH_TOOL" start >> "$LOG_FILE" 2>&1 || return 1
  while [ "$waited" -lt 20 ]; do
    pid=$(agh_pid) || pid=""
    if [ -n "$pid" ] && [ "$(agh_pid_uid "$pid")" = 0 ] &&
       [ "$(agh_pid_gid "$pid")" = "$expected" ]; then
      ss -lnt 2>/dev/null | grep -q "127.0.0.1:$AGH_DNS_PORT " && return 0
    fi
    sleep 1
    waited=$((waited+1))
  done
  return 1
}

agh_url_encode() {
  LC_ALL=C $AWK '
    BEGIN { for(i=1;i<256;i++) ord[sprintf("%c",i)]=i; }
    {
      for(i=1;i<=length($0);i++) {
        c=substr($0,i,1);
        if(c ~ /^[A-Za-z0-9._~-]$/) printf "%s",c;
        else printf "%%%02X",ord[c];
      }
    }
  '
}

agh_proxy_selected() {
  local current="DNS连接" visited="" response="" selected="" type="" encoded=""
  while :; do
    if printf '%s\n' "$visited" | grep -qxF -- "$current"; then
      AGH_STATUS="cyclic_proxy_selection"
      return 1
    fi
    visited="$visited
$current"
    encoded=$(printf '%s\n' "$current" | agh_url_encode)
    response=$(agh_api_get "/proxies/$encoded") || return 1
    type=$(printf '%s\n' "$response" | $SED -n 's/.*"type"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    case "$type" in Direct|Reject|RejectDrop|Pass|Compatible|DNS|Dns)
      AGH_STATUS="requires_proxy_selection"; return 1 ;;
    esac
    selected=$(printf '%s\n' "$response" | $SED -n 's/.*"now"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    case "$selected" in DIRECT|REJECT|REJECT-DROP|PASS|"🌐 本机·本地直连")
      AGH_STATUS="requires_proxy_selection"; return 1 ;;
    esac
    if [ -n "$selected" ]; then current="$selected"; continue; fi
    case "$type" in Selector|URLTest|Fallback|LoadBalance|Relay)
      AGH_STATUS="requires_proxy_selection"; return 1 ;;
    esac
    [ -z "$type" ] || return 0
    # Some provider-backed nodes are absent from /proxies/<display-name>.
    # In that case verify the selected group can reach the actual DoH endpoint.
    if printf '%s\n' "$response" | grep -q 'Resource not found'; then
      response=$(agh_api_get '/proxies/DNS%E8%BF%9E%E6%8E%A5/delay?timeout=4000&url=https%3A%2F%2F1.12.12.12%2Fdns-query%3Fdns%3DAAABAAABAAAAAAAAB2V4YW1wbGUDY29tAAABAAE') || return 1
      printf '%s\n' "$response" | grep -Eq '"delay"[[:space:]]*:[[:space:]]*[0-9]+' && return 0
    fi
    AGH_STATUS="unknown_or_unreachable_proxy"
    return 1
  done
}

agh_api_get() {
  if [ -n "$API_SECRET" ]; then
    "$CURL" --noproxy '*' -sS --max-time 5 \
      -H "Authorization: Bearer $API_SECRET" "http://$API_HOST:$API_PORT$1"
  else
    "$CURL" --noproxy '*' -sS --max-time 5 "http://$API_HOST:$API_PORT$1"
  fi
}

agh_runtime_ready() {
  local pid="" identity="" rules="" response="" selected=""
  AGH_STATUS="waiting_surfing"
  pid=$(pidof "$BOX_BIN_NAME" 2>/dev/null | $AWK '{print $1}')
  [ -n "$pid" ] && [ -n "$CURL" ] && [ -n "$SETUIDGID" ] || return 1
  identity=$($AWK '/^Uid:/{u=$2} /^Gid:/{g=$2} END{print u ":" g}' "/proc/$pid/status")
  [ "$identity" = "0:3005" ] || { AGH_STATUS="unsupported_core_identity"; return 1; }
  identity=$($SETUIDGID root:inet id 2>/dev/null) || return 1
  printf '%s\n' "$identity" | grep -q 'uid=0' &&
    printf '%s\n' "$identity" | grep -q 'gid=3003' ||
    { AGH_STATUS="unsupported_inet_group"; return 1; }
  rules=$(iptables -t mangle -S BOX_LOCAL 2>/dev/null) || return 1
  printf '%s\n' "$rules" | grep -q -- '--uid-owner 0 --gid-owner 3005 -j RETURN' || return 1
  printf '%s\n' "$rules" | grep -q -- '-p tcp -j MARK' || return 1
  parse_controller_info
  response=$(agh_api_get /configs) || return 1
  printf '%s\n' "$response" | grep -Eq '"mode"[[:space:]]*:[[:space:]]*"rule"' ||
    { AGH_STATUS="requires_rule_mode"; return 1; }
  agh_proxy_selected
}

agh_has_changes() {
  [ -s "$AGH_GROUP_BACKUP" ] || [ -s "$AGH_RULES_ADDED" ]
}

agh_backups_valid() {
  local original=""
  if [ -f "$AGH_GROUP_BACKUP" ]; then
    original=$(agh_setting_value "$AGH_GROUP_BACKUP" adg_group) || return 1
    case "$original" in inet|3003|net_admin|3005) ;; *) return 1 ;; esac
  fi
  if [ -f "$AGH_RULES_ADDED" ]; then
    $AWK '
      $0=="  - IP-CIDR,1.12.12.12/32,DNS连接,no-resolve # fix_Surfing_Dns_ikuuu: agh-doh" { a++; next }
      $0=="  - IP-CIDR,120.53.53.53/32,DNS连接,no-resolve # fix_Surfing_Dns_ikuuu: agh-doh" { b++; next }
      $0!="" { bad=1 }
      END { if(bad || a>1 || b>1) exit 1; }
    ' "$AGH_RULES_ADDED" || return 1
  fi
  return 0
}

agh_record_status() {
  AGH_STATUS="$1"
  save_state
}

module_write_disabled() {
  [ -n "${LIVE_MOD_DIR:-}" ] || return 1
  [ -f "$LIVE_MOD_DIR/disable" ] || [ -f "$LIVE_MOD_DIR/remove" ]
}

sync_agh_fix() {
  local reason="$1" own_lock=0 result=0 applied_now=0
  if [ "$LOCK_HELD" != 1 ]; then acquire_lock || return 1; own_lock=1; fi
  if [ -n "${STATE_FILE:-}" ] && [ -f "$STATE_FILE" ]; then . "$STATE_FILE"; fi
  if [ "$AGH_FIX_ENABLED" = 1 ]; then
    if module_write_disabled; then
      log_msg "AGH application cancelled after lock: module disabled/removed"
    else
      if apply_agh_fix "$reason"; then applied_now=1; else result=$?; fi
    fi
  else
    restore_agh_fix "$reason" || result=$?
  fi
  # A disable event may arrive during slow validation/restart and its watcher
  # may time out waiting for our lock. The transaction must also honor it.
  if [ "$applied_now" -eq 1 ] && module_write_disabled; then
    if ! restore_precision_backup disabled_during_apply; then
      log_msg "Late disable restore failed ($AGH_STATUS); recovery data retained"
      agh_record_status rollback_failed
      result=1
    fi
  fi
  [ "$own_lock" -eq 0 ] || release_lock
  return "$result"
}

apply_agh_fix() {
  local reason="$1" user="" group="" port="" first="" node_host="" pid="" running=0 old_gid=3005
  local pre_cfg="$DATA_DIR/agh_config.pre.$$" pre_settings="$DATA_DIR/agh_settings.pre.$$"
  local new_cfg="$DATA_DIR/agh_config.new.$$" new_settings="$DATA_DIR/agh_settings.new.$$"
  local new_record="$DATA_DIR/agh_rules.new.$$" pre_record="$DATA_DIR/agh_rules.pre.$$"
  local made_group_backup=0 failed=0 restore_failed=0

  if [ "$reason" = install ] && [ "$MODPATH" != "$LIVE_MOD_DIR" ]; then
    agh_record_status pending_reboot
    print_out "[*] AGH 联动修复将在重启、加载本版本恢复脚本后应用"
    return 0
  fi
  if [ ! -f "$AGH_SETTINGS" ] || [ ! -f "$AGH_YAML" ]; then
    if agh_has_changes; then
      agh_record_status missing_agh_with_backup
      print_out "[!] AGH 配置已移除，但仍有恢复记录；保留备份，请检查 $BACKUP_DIR"
      return 1
    fi
    agh_record_status not_installed
    return 0
  fi
  if ! agh_backups_valid; then
    agh_record_status invalid_backup
    print_out "[!] AGH 恢复记录损坏或为空，未覆盖恢复点，请检查 $BACKUP_DIR"
    return 1
  fi
  user=$(agh_setting_value "$AGH_SETTINGS" adg_user) || user=""
  group=$(agh_setting_value "$AGH_SETTINGS" adg_group) || group=""
  port=$(agh_setting_value "$AGH_SETTINGS" redir_port) || port=""
  first=$(get_active_psn_entries "$CLASH_CONFIG" | head -n 1)
  node_host=$(printf '%s\n' "$first" | $SED -n 's#^tcp://\([0-9.]*\):[0-9]*$#\1#p')
  if ! agh_upstreams_compatible "$AGH_YAML" ||
     [ "$(agh_setting_value "$AGH_SETTINGS" enable_iptables)" != false ] ||
     { [ "$user" != root ] && [ "$user" != 0 ]; } ||
     ! printf '%s\n' "$first" | grep -Eq '^tcp://[0-9.]+:[0-9]+$' ||
     ! is_usable_public_ipv4 "$node_host" ||
     ! [ -x "$AGH_TOOL" ] ||
     ! grep -qF 'setuidgid "$adg_user:$adg_group"' "$AGH_TOOL"; then
    agh_has_changes && restore_agh_fix "$reason" || {
      if agh_has_changes; then return 1; fi
    }
    agh_record_status unsupported_configuration
    print_out "[!] 跳过 AGH 修复：需要 root、独立 IP 节点 DNS、IP 格式 DNSPod DoH 和 enable_iptables=false"
    return 0
  fi
  case "$group" in
    inet|3003) old_gid=3003 ;;
    net_admin|3005) old_gid=3005 ;;
    *)
      agh_record_status conflicting_group
      print_out "[!] AGH 使用其他用户组，未覆盖用户配置；已有恢复记录保留"
      return 1 ;;
  esac
  case "$port" in ""|*[!0-9]*) agh_record_status invalid_dns_port; return 1 ;; esac
  if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    agh_record_status invalid_dns_port
    return 1
  fi
  AGH_DNS_PORT="$port"
  if agh_rules_conflict "$CLASH_CONFIG" "$AGH_RULES_ADDED"; then
    agh_record_status conflicting_rules
    print_out "[!] 模块标记规则已被用户修改，保留规则及原恢复记录"
    return 1
  fi
  if ! agh_runtime_ready; then
    save_state
    print_out "[!] AGH 暂未应用 ($AGH_STATUS)：需 Surfing 规则模式、可用 DNS连接 代理组和透明接管规则"
    return 0
  fi
  if pid=$(agh_pid); then
    running=1
    if [ "$(agh_pid_uid "$pid")" != 0 ]; then
      agh_record_status unexpected_agh_identity
      return 1
    fi
  else
    [ "$?" -eq 1 ] || { agh_record_status multiple_agh_processes; return 1; }
  fi
  if agh_rules_ready "$CLASH_CONFIG" && [ "$old_gid" -eq 3003 ] &&
     { [ "$running" -eq 0 ] || [ "$(agh_pid_gid "$pid")" = 3003 ]; }; then
    AGH_APPLIED=1
    agh_record_status active
    return 0
  fi

  _agh_clean_apply() {
    rm -f "$pre_cfg" "$pre_settings" "$new_cfg" "$new_settings" "$new_record" "$pre_record"
  }
  if ! cp -f "$CLASH_CONFIG" "$pre_cfg" || ! cp -f "$AGH_SETTINGS" "$pre_settings"; then
    _agh_clean_apply
    return 1
  fi
  chmod 600 "$pre_cfg" "$pre_settings"
  if [ -f "$AGH_RULES_ADDED" ]; then
    cp -f "$AGH_RULES_ADDED" "$pre_record" || { _agh_clean_apply; return 1; }
  else
    : > "$pre_record"
  fi
  if [ "$old_gid" -eq 3003 ]; then
    cp -f "$AGH_SETTINGS" "$new_settings" || { _agh_clean_apply; return 1; }
  else
    agh_write_group "$AGH_SETTINGS" inet "$new_settings" || { _agh_clean_apply; return 1; }
  fi
  if ! agh_build_rules "$CLASH_CONFIG" "$new_cfg" "$new_record" ||
     ! validate_config_file "$new_cfg"; then
    _agh_clean_apply
    agh_record_status validation_failed
    return 1
  fi
  if [ "$old_gid" -eq 3005 ] && [ ! -f "$AGH_GROUP_BACKUP" ]; then
    if ! $AWK '/^[[:space:]]*adg_group[[:space:]]*=/ { print }' "$AGH_SETTINGS" > "$AGH_GROUP_BACKUP.new.$$" ||
       ! agh_setting_value "$AGH_GROUP_BACKUP.new.$$" adg_group >/dev/null; then
      rm -f "$AGH_GROUP_BACKUP.new.$$"
      _agh_clean_apply
      return 1
    fi
    chmod 600 "$AGH_GROUP_BACKUP.new.$$"
    if ! mv -f "$AGH_GROUP_BACKUP.new.$$" "$AGH_GROUP_BACKUP"; then
      rm -f "$AGH_GROUP_BACKUP.new.$$"
      _agh_clean_apply
      return 1
    fi
    made_group_backup=1
  fi
  if ! cp -f "$new_record" "$AGH_RULES_ADDED.new.$$" ||
     ! mv -f "$AGH_RULES_ADDED.new.$$" "$AGH_RULES_ADDED"; then
    rm -f "$AGH_RULES_ADDED.new.$$"
    [ "$made_group_backup" -eq 0 ] || rm -f "$AGH_GROUP_BACKUP"
    _agh_clean_apply
    return 1
  fi
  chmod 600 "$AGH_RULES_ADDED"
  if ! copy_file_preserve_meta "$new_cfg" "$CLASH_CONFIG" ||
     ! reload_surfing_if_running ||
     ! copy_file_preserve_meta "$new_settings" "$AGH_SETTINGS" ||
     ! agh_restart_running "$running" 3003; then
    failed=1
  fi
  if [ "$failed" -eq 1 ]; then
    # Keep proxy rules until the original AGH launch identity is back.
    copy_file_preserve_meta "$pre_settings" "$AGH_SETTINGS" || restore_failed=1
    agh_restart_running "$running" "$old_gid" || restore_failed=1
    if [ "$restore_failed" -eq 0 ]; then
      copy_file_preserve_meta "$pre_cfg" "$CLASH_CONFIG" || restore_failed=1
      reload_surfing_if_running || restore_failed=1
    fi
    if [ "$restore_failed" -eq 0 ]; then
      if cp -f "$pre_record" "$AGH_RULES_ADDED"; then
        [ "$made_group_backup" -eq 0 ] || rm -f "$AGH_GROUP_BACKUP"
      else
        restore_failed=1
      fi
    fi
    if [ "$restore_failed" -eq 0 ]; then
      agh_record_status apply_failed_rolled_back
      _agh_clean_apply
    else
      agh_record_status rollback_failed
      print_out "[!] AGH 回滚未完成，保留 $BACKUP_DIR 和本次临时快照供恢复"
    fi
    return 1
  fi
  AGH_APPLIED=1
  agh_record_status active
  print_out "[+] AGH 联动已应用：用户组 inet，两个 DNSPod 上游通过 DNS连接 分流"
  _agh_clean_apply
  return 0
}

restore_agh_fix() {
  local reason="$1" group="" original="" expected=3005 running=0 port=""
  local restored_settings="$DATA_DIR/agh_settings.restore.$$"
  local restored_cfg="$DATA_DIR/agh_config.restore.$$"
  if ! agh_backups_valid; then
    agh_record_status invalid_backup
    return 1
  fi
  if ! agh_has_changes; then
    AGH_APPLIED=0
    agh_record_status inactive
    return 0
  fi
  if [ -s "$AGH_RULES_ADDED" ] && [ -f "$CLASH_CONFIG" ] &&
     agh_rules_conflict "$CLASH_CONFIG" "$AGH_RULES_ADDED"; then
    agh_record_status restore_rules_conflict
    return 1
  fi
  if [ -s "$AGH_GROUP_BACKUP" ]; then
    if [ ! -f "$AGH_SETTINGS" ] ||
       ! agh_restore_group "$AGH_SETTINGS" "$AGH_GROUP_BACKUP" "$restored_settings"; then
      rm -f "$restored_settings"
      agh_record_status restore_group_conflict
      return 1
    fi
    original=$(agh_setting_value "$AGH_GROUP_BACKUP" adg_group) || return 1
    case "$original" in inet|3003) expected=3003 ;; net_admin|3005) expected=3005 ;; *) return 1 ;; esac
    port=$(agh_setting_value "$AGH_SETTINGS" redir_port) || return 1
    AGH_DNS_PORT="$port"
    if group=$(agh_pid); then
      running=1
      [ "$(agh_pid_uid "$group")" = 0 ] || return 1
    else
      [ "$?" -eq 1 ] || return 1
    fi
    if ! copy_file_preserve_meta "$restored_settings" "$AGH_SETTINGS" ||
       ! agh_restart_running "$running" "$expected"; then
      rm -f "$restored_settings"
      agh_record_status restore_restart_failed
      return 1
    fi
    rm -f "$restored_settings"
  fi
  if [ -s "$AGH_RULES_ADDED" ]; then
    if [ ! -f "$CLASH_CONFIG" ] ||
       ! agh_remove_rules "$CLASH_CONFIG" "$AGH_RULES_ADDED" "$restored_cfg" ||
       ! validate_config_file "$restored_cfg" ||
       ! copy_file_preserve_meta "$restored_cfg" "$CLASH_CONFIG" ||
       ! reload_surfing_if_running; then
      rm -f "$restored_cfg"
      agh_record_status restore_rules_failed
      return 1
    fi
    rm -f "$restored_cfg"
  fi
  rm -f "$AGH_GROUP_BACKUP" "$AGH_RULES_ADDED"
  AGH_APPLIED=0
  agh_record_status inactive
  log_msg "AGH owned changes restored ($reason)"
  return 0
}
