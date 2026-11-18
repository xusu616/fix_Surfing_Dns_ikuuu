#!/system/bin/sh
# Shared helper library for fix_Surfing_Dns_ikuuu (Magisk / KernelSU / APatch)

init_env() {
  MOD_ID="fix_Surfing_Dns_ikuuu"
  DATA_DIR="/data/adb/${MOD_ID}"
  BACKUP_DIR="${DATA_DIR}/backup"
  SETTINGS_FILE="${DATA_DIR}/settings.conf"
  STATE_FILE="${DATA_DIR}/state.conf"
  LOG_FILE="${DATA_DIR}/module.log"

  BACKUP_FULL="${BACKUP_DIR}/config.yaml.pre_module"
  BACKUP_PSN="${BACKUP_DIR}/proxy_server_nameserver.orig"
  BACKUP_PSN_META="${BACKUP_DIR}/psn_meta.conf"
  BACKUP_CN_IP="${BACKUP_DIR}/cn_ip_rule.orig"

  BOX_DIR="/data/adb/box_bll"
  CLASH_DIR="${BOX_DIR}/clash"
  CLASH_CONFIG="${CLASH_DIR}/config.yaml"
  PROXIES_DIR="${CLASH_DIR}/proxies"
  SURFING_SCRIPTS="${BOX_DIR}/scripts"
  BOX_CONFIG="${SURFING_SCRIPTS}/box.config"

  MODULES_BASE="/data/adb/modules"
  if command -v magisk >/dev/null 2>&1; then
    if magisk -v 2>/dev/null | grep -qi "lite"; then
      MODULES_BASE="/data/adb/lite_modules"
    fi
  fi
  LIVE_MOD_DIR="${MODULES_BASE}/${MOD_ID}"

  mkdir -p "$DATA_DIR" "$BACKUP_DIR"

  # Locate BusyBox across KernelSU / APatch / Magisk / Surfing
  local _bb=""
  BUSYBOX=""
  for _bb in \
    /data/adb/ksu/bin/busybox \
    /data/adb/ap/bin/busybox \
    /data/adb/magisk/busybox \
    /data/adb/box_bll/bin/busybox \
    "$(command -v busybox 2>/dev/null)"; do
    if [ -n "$_bb" ] && [ -x "$_bb" ]; then
      BUSYBOX="$_bb"
      break
    fi
  done

  if [ -n "$BUSYBOX" ]; then
    AWK="$BUSYBOX awk"
    SED="$BUSYBOX sed"
    NSLOOKUP="$BUSYBOX nslookup"
    NC="$BUSYBOX nc"
    INOTIFYD="$BUSYBOX inotifyd"
    SETUIDGID="$BUSYBOX setuidgid"
    PKILL="$BUSYBOX pkill"
    PGREP="$BUSYBOX pgrep"
    SETSID="$BUSYBOX setsid"
    TIMEOUT_BIN="$BUSYBOX timeout"
  else
    AWK="awk"
    SED="sed"
    NSLOOKUP="nslookup"
    NC="nc"
    INOTIFYD="inotifyd"
    SETUIDGID=""
    PKILL=$(command -v pkill 2>/dev/null || true)
    PGREP=$(command -v pgrep 2>/dev/null || true)
    SETSID=$(command -v setsid 2>/dev/null || true)
    TIMEOUT_BIN=$(command -v timeout 2>/dev/null || true)
  fi

  if [ -n "$TIMEOUT_BIN" ] && ! $TIMEOUT_BIN 1 true >/dev/null 2>&1; then
    TIMEOUT_BIN=$(command -v timeout 2>/dev/null || true)
    [ -n "$TIMEOUT_BIN" ] && ! $TIMEOUT_BIN 1 true >/dev/null 2>&1 && TIMEOUT_BIN=""
  fi

  CAN_SETUIDGID="0"
  if [ -n "$SETUIDGID" ] && $SETUIDGID 0:3005 true >/dev/null 2>&1; then
    CAN_SETUIDGID="1"
  fi

  local _c=""
  CURL=""
  for _c in /system/bin/curl /data/adb/box_bll/bin/curl "$(command -v curl 2>/dev/null)"; do
    if [ -n "$_c" ] && [ -x "$_c" ]; then
      CURL="$_c"
      break
    fi
  done

  # Locate Clash / Mihomo binary from Surfing box.config
  BOX_BIN=""
  BOX_BIN_NAME=""
  if [ -f "$BOX_CONFIG" ]; then
    BOX_BIN_NAME=$($SED -n 's/^[[:space:]]*bin_name=["'\'']\{0,1\}\([^"'\''[:space:]#]*\).*/\1/p' "$BOX_CONFIG" | head -n 1)
  fi
  local _b=""
  for _b in "${BOX_DIR}/bin/${BOX_BIN_NAME}" "${BOX_DIR}/bin/clash" "${BOX_DIR}/bin/mihomo"; do
    if [ -n "$_b" ] && [ -x "$_b" ]; then
      BOX_BIN="$_b"
      [ -z "$BOX_BIN_NAME" ] && BOX_BIN_NAME="${_b##*/}"
      break
    fi
  done

  # Load saved settings with defaults
  DNS_WRITE_MODE="ip"
  REPLACE_MODE="replace"
  ADD_CN_IP_NORESOLVE="1"
  AUTO_BOOT_SYNC="0"
  [ -f "$SETTINGS_FILE" ] && . "$SETTINGS_FILE"

  # Load module state with defaults
  APPLIED="0"
  LAST_APPLIED_DNS=""
  LAST_STATUS="init"
  NO_RESOLVE_APPLIED="0"
  [ -f "$STATE_FILE" ] && . "$STATE_FILE"
}

log_msg() {
  local _ts=""
  _ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")
  if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)" -gt 204800 ]; then
    mv -f "$LOG_FILE" "${LOG_FILE}.old" 2>/dev/null
  fi
  printf '[%s] %s\n' "$_ts" "$1" >> "$LOG_FILE" 2>/dev/null
}

print_out() {
  log_msg "$1"
  if command -v ui_print >/dev/null 2>&1; then
    ui_print "$1"
  else
    printf '%s\n' "$1"
  fi
}

short_sleep() {
  if [ -n "$BUSYBOX" ]; then
    $BUSYBOX usleep 200000 2>/dev/null || sleep 1
  else
    sleep 1
  fi
}

LOCK_DIR=""
LOCK_HELD="0"

acquire_lock() {
  LOCK_DIR="${DATA_DIR}/.op.lock"
  local _waited=0 _holder=""
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    _holder=$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)
    if [ -n "$_holder" ] && ! kill -0 "$_holder" 2>/dev/null; then
      rm -rf "$LOCK_DIR" 2>/dev/null || true
      continue
    fi
    _waited=$((_waited + 1))
    [ "$_waited" -ge 150 ] && return 1
    short_sleep
  done
  printf '%s\n' "$$" > "${LOCK_DIR}/pid" 2>/dev/null || true
  LOCK_HELD="1"
  return 0
}

release_lock() {
  if [ "$LOCK_HELD" = "1" ] && [ -n "$LOCK_DIR" ]; then
    rm -rf "$LOCK_DIR" 2>/dev/null || true
    LOCK_HELD="0"
  fi
}

save_settings() {
  cat <<EOF > "$SETTINGS_FILE"
DNS_WRITE_MODE="${DNS_WRITE_MODE}"
REPLACE_MODE="${REPLACE_MODE}"
ADD_CN_IP_NORESOLVE="${ADD_CN_IP_NORESOLVE}"
AUTO_BOOT_SYNC="${AUTO_BOOT_SYNC}"
EOF
  chmod 0644 "$SETTINGS_FILE"
}

save_state() {
  cat <<EOF > "$STATE_FILE"
APPLIED="${APPLIED}"
LAST_APPLIED_DNS="${LAST_APPLIED_DNS}"
LAST_STATUS="${LAST_STATUS}"
NO_RESOLVE_APPLIED="${NO_RESOLVE_APPLIED}"
EOF
  chmod 0644 "$STATE_FILE"
}

is_valid_ipv4() {
  printf '%s\n' "$1" | $AWK '
    /^[0-9]{1,3}(\.[0-9]{1,3}){3}$/ {
      split($0, a, ".");
      for (i = 1; i <= 4; i++) {
        if (a[i] + 0 < 0 || a[i] + 0 > 255) exit 1;
      }
      exit 0;
    }
    { exit 1 }
  '
}

is_usable_public_ipv4() {
  is_valid_ipv4 "$1" || return 1
  local _o1="" _o2=""
  _o1="${1%%.*}"
  _o2="${1#*.}"
  _o2="${_o2%%.*}"
  case "$_o1" in
    0|10|127|224|240|255) return 1 ;;
    100) [ "$_o2" -ge 64 ] && [ "$_o2" -le 127 ] && return 1 ;;
    169) [ "$_o2" -eq 254 ] && return 1 ;;
    172) [ "$_o2" -ge 16 ] && [ "$_o2" -le 31 ] && return 1 ;;
    192) [ "$_o2" -eq 168 ] && return 1 ;;
    198) case "$_o2" in 18|19) return 1 ;; esac ;;
  esac
  [ "$_o1" -ge 224 ] && return 1
  return 0
}

list_proxy_files() {
  [ -d "$PROXIES_DIR" ] || return 1
  local _f="" _found=0
  for _f in "$PROXIES_DIR"/*.yaml "$PROXIES_DIR"/*.yml; do
    if [ -f "$_f" ]; then
      printf '%s\n' "$_f"
      _found=1
    fi
  done
  [ "$_found" -eq 1 ]
}

# Extract tcp://host(:port) entries from dns.nameserver-policy inside proxies/*.yaml|yml
extract_sub_dns_entries() {
  local _files="" _f="" _tmp_raw="${DATA_DIR}/.sub_dns.$$.tmp"
  _files=$(list_proxy_files) || return 1
  : > "$_tmp_raw"

  while IFS= read -r _f; do
    [ -f "$_f" ] || continue
    $AWK '
      BEGIN { in_dns = 0; in_ns_policy = 0; ns_indent = -1; }
      /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
      {
        match($0, /^[[:space:]]*/);
        ind = RLENGTH;
        line = substr($0, ind + 1);
        sub(/[[:space:]]+#.*$/, "", line);
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line);

        if (ind == 0) {
          in_dns = (line ~ /^dns:[[:space:]]*$/) ? 1 : 0;
          in_ns_policy = 0;
          ns_indent = -1;
          next;
        }
        if (!in_dns) next;

        if (!in_ns_policy) {
          if (line ~ /^nameserver-policy:[[:space:]]*\{/) {
            # Inline flow map on same line
            while (match(line, /tcp:\/\/[A-Za-z0-9._-]+(:[0-9]+)?/)) {
              url = substr(line, RSTART, RLENGTH);
              if (url !~ /:[0-9]+$/) url = url ":8080";
              if (url !~ /^tcp:\/\/(127\.0\.0\.1|0\.0\.0\.0|localhost)(:|$)/) print url;
              line = substr(line, RSTART + RLENGTH);
            }
          } else if (line ~ /^nameserver-policy:[[:space:]]*$/) {
            in_ns_policy = 1;
            ns_indent = ind;
          }
          next;
        }

        if (ind <= ns_indent) {
          in_ns_policy = 0;
          ns_indent = -1;
          next;
        }

        while (match(line, /tcp:\/\/[A-Za-z0-9._-]+(:[0-9]+)?/)) {
          url = substr(line, RSTART, RLENGTH);
          if (url !~ /:[0-9]+$/) url = url ":8080";
          if (url !~ /^tcp:\/\/(127\.0\.0\.1|0\.0\.0\.0|localhost)(:|$)/) print url;
          line = substr(line, RSTART + RLENGTH);
        }
      }
    ' "$_f" >> "$_tmp_raw"
  done <<EOF
$_files
EOF

  $AWK '!seen[$0]++' "$_tmp_raw"
  rm -f "$_tmp_raw"
}

# Extract a real proxy entry hostname from proxies/*.yaml|yml for live DNS resolution check
extract_test_entry_domain() {
  local _files="" _f="" _dom=""
  _files=$(list_proxy_files) || return 1
  while IFS= read -r _f; do
    [ -f "$_f" ] || continue
    _dom=$($AWK '
      /^[[:space:]]*#/ { next }
      {
        if (match($0, /server:[[:space:]]*["'\'']?[A-Za-z0-9.-]+["'\'']?/)) {
          s = substr($0, RSTART, RLENGTH);
          sub(/^server:[[:space:]]*["'\'']?/, "", s);
          sub(/["'\'']$/, "", s);
          if (s ~ /[a-zA-Z]/ && s !~ /^(localhost|127\.0\.0\.1)$/ && s ~ /\./) {
            print s;
            exit;
          }
        }
      }
    ' "$_f")
    if [ -n "$_dom" ]; then
      printf '%s\n' "$_dom"
      return 0
    fi
  done <<EOF
$_files
EOF
  return 1
}

parse_nslookup_ipv4() {
  $AWK '
    /^Name:/ { in_ans = 1; next }
    in_ans && /Address/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
          print $i;
        }
      }
    }
  '
}

pick_first_usable_ipv4() {
  local _cand=""
  while IFS= read -r _cand; do
    if is_usable_public_ipv4 "$_cand"; then
      printf '%s\n' "$_cand"
      return 0
    fi
  done
  return 1
}

run_nslookup_timeout() {
  local _sec="$1" _bypass="$2" _host="$3" _srv="$4"
  if [ "$_bypass" = "1" ] && [ "$CAN_SETUIDGID" = "1" ]; then
    if [ -n "$TIMEOUT_BIN" ]; then
      if [ -n "$_srv" ]; then
        $TIMEOUT_BIN "$_sec" $SETUIDGID 0:3005 $NSLOOKUP "$_host" "$_srv" 2>/dev/null
      else
        $TIMEOUT_BIN "$_sec" $SETUIDGID 0:3005 $NSLOOKUP "$_host" 2>/dev/null
      fi
    else
      if [ -n "$_srv" ]; then
        $SETUIDGID 0:3005 $NSLOOKUP "$_host" "$_srv" 2>/dev/null
      else
        $SETUIDGID 0:3005 $NSLOOKUP "$_host" 2>/dev/null
      fi
    fi
  else
    if [ -n "$TIMEOUT_BIN" ]; then
      if [ -n "$_srv" ]; then
        $TIMEOUT_BIN "$_sec" $NSLOOKUP "$_host" "$_srv" 2>/dev/null
      else
        $TIMEOUT_BIN "$_sec" $NSLOOKUP "$_host" 2>/dev/null
      fi
    else
      if [ -n "$_srv" ]; then
        $NSLOOKUP "$_host" "$_srv" 2>/dev/null
      else
        $NSLOOKUP "$_host" 2>/dev/null
      fi
    fi
  fi
}

resolve_host_to_ip() {
  local _host="$1"
  local _ip="" _out="" _dns="" _url="" _json=""

  if is_valid_ipv4 "$_host"; then
    printf '%s\n' "$_host"
    return 0
  fi

  # 1. Try bypassing Clash CLASH_DNS_LOCAL (UID 0 GID 3005 is exempted in Surfing iptables)
  if [ "$CAN_SETUIDGID" = "1" ]; then
    for _dns in 223.5.5.5 119.29.29.29; do
      _out=$(run_nslookup_timeout 4 1 "$_host" "$_dns")
      _ip=$(printf '%s\n' "$_out" | parse_nslookup_ipv4 | pick_first_usable_ipv4)
      if [ -n "$_ip" ]; then
        printf '%s\n' "$_ip"
        return 0
      fi
    done
  fi

  # 2. Try standard nslookup against public DNS and system default
  for _dns in 223.5.5.5 119.29.29.29 ""; do
    _out=$(run_nslookup_timeout 4 0 "$_host" "$_dns")
    _ip=$(printf '%s\n' "$_out" | parse_nslookup_ipv4 | pick_first_usable_ipv4)
    if [ -n "$_ip" ]; then
      printf '%s\n' "$_ip"
      return 0
    fi
  done

  # 3. Try DoH JSON API via curl (bypasses UDP/53 hijacks completely)
  if [ -n "$CURL" ]; then
    for _url in \
      "https://223.5.5.5/resolve?name=${_host}&type=1" \
      "https://1.12.12.12/resolve?name=${_host}&type=1"; do
      _json=""
      if [ "$CAN_SETUIDGID" = "1" ]; then
        _json=$($SETUIDGID 0:3005 "$CURL" -sS --max-time 4 -H "Accept: application/dns-json" "$_url" 2>/dev/null)
      fi
      [ -z "$_json" ] && _json=$("$CURL" -sS --max-time 4 -H "Accept: application/dns-json" "$_url" 2>/dev/null)
      _ip=$(printf '%s' "$_json" | $AWK '{
        while (match($0, /"data"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"/)) {
          seg = substr($0, RSTART, RLENGTH);
          sub(/^"data"[[:space:]]*:[[:space:]]*"/, "", seg);
          sub(/"$/, "", seg);
          print seg;
          $0 = substr($0, RSTART + RLENGTH);
        }
      }' | pick_first_usable_ipv4)
      if [ -n "$_ip" ]; then
        printf '%s\n' "$_ip"
        return 0
      fi
    done
  fi

  return 1
}

build_target_dns_entries() {
  local _raw_list="" _line="" _hostport="" _host="" _port="" _ip="" _entry=""
  _raw_list=$(extract_sub_dns_entries)
  [ -z "$_raw_list" ] && return 1

  RESOLVE_SUMMARY=""
  USED_DOMAIN_FALLBACK="0"
  TARGET_DNS_LIST=""

  while IFS= read -r _line; do
    [ -z "$_line" ] && continue
    _hostport="${_line#tcp://}"
    _host="${_hostport%%:*}"
    _port="${_hostport##*:}"
    [ -z "$_port" ] && _port="8080"

    if [ "$DNS_WRITE_MODE" = "ip" ]; then
      if _ip=$(resolve_host_to_ip "$_host"); then
        _entry="tcp://${_ip}:${_port}"
        RESOLVE_SUMMARY="${RESOLVE_SUMMARY}${_host} -> ${_ip}:${_port}; "
      else
        _entry="tcp://${_host}:${_port}"
        USED_DOMAIN_FALLBACK="1"
        RESOLVE_SUMMARY="${RESOLVE_SUMMARY}${_host} -> fallback(domain); "
      fi
    else
      _entry="tcp://${_host}:${_port}"
      RESOLVE_SUMMARY="${RESOLVE_SUMMARY}${_host}:${_port}(domain); "
    fi

    case "
${TARGET_DNS_LIST}
" in
      *"
${_entry}
"*) ;;
      *)
        if [ -z "$TARGET_DNS_LIST" ]; then
          TARGET_DNS_LIST="$_entry"
        else
          TARGET_DNS_LIST="${TARGET_DNS_LIST}
${_entry}"
        fi
        ;;
    esac
  done <<EOF
$_raw_list
EOF

  [ -n "$TARGET_DNS_LIST" ]
}

# Inspect proxy-server-nameserver block inside dns:
# Outputs: "<had_block> <start_line> <end_line> <indent> <insert_before_line>"
inspect_psn_block() {
  local _cfg="$1"
  $AWK '
    BEGIN {
      in_dns = 0; dns_start = 0; dns_end = 0; dns_child_indent = 0;
      had = 0; psn_start = 0; psn_end = 0; psn_indent = 2;
      in_psn = 0; insert_before = 0;
    }
    {
      line = $0;
      is_blank = (line ~ /^[[:space:]]*$/);
      is_comment = (line ~ /^[[:space:]]*#/);
      match(line, /^[[:space:]]*/);
      ind = RLENGTH;
      content = substr(line, ind + 1);

      if (!is_blank && !is_comment && ind == 0) {
        if (in_dns) {
          dns_end = NR - 1;
          in_dns = 0;
          in_psn = 0;
        }
        if (content ~ /^dns:[[:space:]]*(#.*)?$/) {
          in_dns = 1;
          dns_start = NR;
        }
        next;
      }

      if (!in_dns) next;

      if (!is_blank && !is_comment && dns_child_indent == 0 && ind > 0) {
        dns_child_indent = ind;
      }

      if (in_psn) {
        # Support standard indented items (ind > psn_indent) AND zero-extra-indent sequences (ind == psn_indent && starts with "-")
        is_seq_item = (content ~ /^-[[:space:]]/ || content ~ /^-[[:space:]]*$/);
        if (!is_blank && !is_comment && (ind < psn_indent || (ind == psn_indent && !is_seq_item))) {
          in_psn = 0;
        } else if (!is_blank && (ind > psn_indent || (ind == psn_indent && is_seq_item) || (is_comment && ind >= psn_indent))) {
          psn_end = NR;
        }
      }

      if (!is_blank && !is_comment) {
        if (content ~ /^proxy-server-nameserver:[[:space:]]*(\[.*\])?[[:space:]]*(#.*)?$/) {
          had = 1;
          psn_start = NR;
          psn_end = NR;
          psn_indent = ind;
          in_psn = 1;
        } else if (insert_before == 0 && content ~ /^(nameserver-policy|nameserver|direct-nameserver):/) {
          insert_before = NR;
        }
      }
    }
    END {
      if (in_dns && dns_end == 0) dns_end = NR;
      if (!had && dns_child_indent > 0) psn_indent = dns_child_indent;
      if (insert_before == 0) {
        if (dns_end >= dns_start && dns_start > 0) insert_before = dns_end + 1;
        else insert_before = 0;
      }
      printf "%d %d %d %d %d\n", had, psn_start, psn_end, psn_indent, insert_before;
    }
  ' "$_cfg"
}

get_active_psn_entries() {
  local _cfg="$1"
  local _info="" _had="" _s="" _e=""
  _info=$(inspect_psn_block "$_cfg")
  set -- $_info
  _had="$1"; _s="$2"; _e="$3"
  [ "$_had" = "1" ] && [ "$_s" -gt 0 ] && [ "$_e" -ge "$_s" ] || return 0
  $SED -n "${_s},${_e}p" "$_cfg" | $AWK '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
      line = $0;
      sub(/^[[:space:]]+/, "", line);
      if (line ~ /^proxy-server-nameserver:[[:space:]]*\[/) {
        sub(/^proxy-server-nameserver:[[:space:]]*\[/, "", line);
        sub(/\][[:space:]]*(#.*)?$/, "", line);
        n = split(line, arr, ",");
        for (i = 1; i <= n; i++) {
          v = arr[i];
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", v);
          gsub(/^["'\'']|["'\'']$/, "", v);
          if (v != "") print v;
        }
        next;
      }
      if (line ~ /^-[[:space:]]+/) {
        sub(/^-[[:space:]]+/, "", line);
        # Strip inline comment only when preceded by whitespace (preserve #proxy-group tags!)
        sub(/[[:space:]]+#.*$/, "", line);
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line);
        gsub(/^["'\'']|["'\'']$/, "", line);
        if (line != "") print line;
      }
    }
  '
}

capture_precision_backup() {
  local _cfg="$1"
  [ -f "$_cfg" ] || return 1

  if [ ! -f "$BACKUP_FULL" ]; then
    cp -f "$_cfg" "$BACKUP_FULL"
    chmod 0644 "$BACKUP_FULL"
  fi

  local _info="" _had="" _s="" _e="" _ind="" _ins=""
  _info=$(inspect_psn_block "$_cfg")
  set -- $_info
  _had="$1"; _s="$2"; _e="$3"; _ind="$4"; _ins="$5"

  printf 'ORIGINAL_HAD_BLOCK=%s\nPSN_INDENT=%s\n' "$_had" "$_ind" > "$BACKUP_PSN_META"
  chmod 0644 "$BACKUP_PSN_META"

  if [ "$_had" = "1" ] && [ "$_s" -gt 0 ] && [ "$_e" -ge "$_s" ]; then
    $SED -n "${_s},${_e}p" "$_cfg" > "$BACKUP_PSN"
  else
    : > "$BACKUP_PSN"
  fi
  chmod 0644 "$BACKUP_PSN"

  # Record CN_IP rules tagged with occurrence index so duplicate rules with/without ,no-resolve restore safely
  $AWK '
    function norm_cn(s,    cpos, body, q) {
      cpos = match(s, /[[:space:]]+#/);
      body = (cpos > 0) ? substr(s, 1, cpos - 1) : s;
      sub(/[[:space:]]+$/, "", body);
      q = "";
      if (body ~ /["'\'']$/) {
        q = substr(body, length(body), 1);
        body = substr(body, 1, length(body) - 1);
      }
      sub(/,no-resolve$/, "", body);
      return body q;
    }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    /^[[:space:]]*-[[:space:]]*["'\'']?RULE-SET,CN_IP,/ {
      k = norm_cn($0);
      cnt[k]++;
      print cnt[k] "\t" $0;
    }
  ' "$_cfg" > "$BACKUP_CN_IP"
  chmod 0644 "$BACKUP_CN_IP"
}

# Build replacement proxy-server-nameserver block file cleanly in AWK (no IFS hazard)
generate_psn_block_file() {
  local _orig_block="$1"
  local _indent_len="$2"
  local _out_file="$3"
  local _exclude_csv="$4"
  local _spaces="" _i=0

  while [ "$_i" -lt "$_indent_len" ]; do
    _spaces="${_spaces} "
    _i=$((_i + 1))
  done

  : > "$_out_file"
  printf '%sproxy-server-nameserver:\n' "$_spaces" >> "$_out_file"

  local _dns=""
  while IFS= read -r _dns; do
    [ -z "$_dns" ] && continue
    printf '%s  - %s\n' "$_spaces" "$_dns" >> "$_out_file"
  done <<EOF
$TARGET_DNS_LIST
EOF

  if [ "$REPLACE_MODE" = "prepend" ] && [ -s "$_orig_block" ]; then
    local _targets_csv=""
    _targets_csv=$(printf '%s\n' "$TARGET_DNS_LIST" | tr '\n' ',')
    $AWK -v sp="$_spaces" -v tcsv="$_targets_csv" -v xcsv="$_exclude_csv" '
      BEGIN {
        n = split(tcsv, ta, ",");
        for (i = 1; i <= n; i++) if (ta[i] != "") skip[ta[i]] = 1;
        m = split(xcsv, xa, ",");
        for (i = 1; i <= m; i++) if (xa[i] != "") skip[xa[i]] = 1;
      }
      function emit(val) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", val);
        gsub(/^["'\'']|["'\'']$/, "", val);
        if (val == "") return;
        # AGH compatibility: ignore any 127.0.0.1 / localhost / 0.0.0.0 entry in proxy-server-nameserver
        if (val ~ /^([a-zA-Z0-9+.-]+:\/\/)?(127\.0\.0\.1|localhost|0\.0\.0\.0)(:|\/|$)/) return;
        if (!(val in skip)) {
          skip[val] = 1;
          printf "%s  - %s\n", sp, val;
        }
      }
      /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
      {
        line = $0;
        sub(/^[[:space:]]+/, "", line);
        if (line ~ /^proxy-server-nameserver:[[:space:]]*\[/) {
          sub(/^proxy-server-nameserver:[[:space:]]*\[/, "", line);
          sub(/\][[:space:]]*(#.*)?$/, "", line);
          k = split(line, arr, ",");
          for (i = 1; i <= k; i++) emit(arr[i]);
          next;
        }
        if (line ~ /^-[[:space:]]+/) {
          sub(/^-[[:space:]]+/, "", line);
          sub(/[[:space:]]+#.*$/, "", line);
          emit(line);
        }
      }
    ' "$_orig_block" >> "$_out_file"
  fi
}

splice_psn_block() {
  local _cfg="$1"
  local _block_file="$2"
  local _out_cfg="$3"
  local _info="" _had="" _s="" _e="" _ind="" _ins=""

  _info=$(inspect_psn_block "$_cfg")
  set -- $_info
  _had="$1"; _s="$2"; _e="$3"; _ind="$4"; _ins="$5"

  if [ "$_had" = "1" ] && [ "$_s" -gt 0 ] && [ "$_e" -ge "$_s" ]; then
    $AWK -v s="$_s" -v e="$_e" -v bfile="$_block_file" '
      NR == s {
        while ((getline bline < bfile) > 0) print bline;
        close(bfile);
      }
      NR >= s && NR <= e { next }
      { print $0 }
    ' "$_cfg" > "$_out_cfg"
  elif [ "$_ins" -gt 0 ]; then
    $AWK -v ins="$_ins" -v bfile="$_block_file" '
      NR == ins {
        while ((getline bline < bfile) > 0) print bline;
        close(bfile);
      }
      { print $0 }
      END {
        if (ins > NR) {
          while ((getline bline < bfile) > 0) print bline;
          close(bfile);
        }
      }
    ' "$_cfg" > "$_out_cfg"
  else
    return 1
  fi
}

delete_psn_block() {
  local _cfg="$1"
  local _out_cfg="$2"
  local _info="" _had="" _s="" _e="" _ind="" _ins=""

  _info=$(inspect_psn_block "$_cfg")
  set -- $_info
  _had="$1"; _s="$2"; _e="$3"; _ind="$4"; _ins="$5"

  if [ "$_had" = "1" ] && [ "$_s" -gt 0 ] && [ "$_e" -ge "$_s" ]; then
    $SED "${_s},${_e}d" "$_cfg" > "$_out_cfg"
  else
    cp -f "$_cfg" "$_out_cfg"
  fi
}

# Add ,no-resolve idempotently to active RULE-SET,CN_IP lines (handles quotes & tab/space comments)
apply_cn_ip_no_resolve() {
  local _cfg="$1"
  local _out_cfg="$2"

  $AWK '
    /^[[:space:]]*-[[:space:]]*["'\'']?RULE-SET,CN_IP,/ {
      cpos = match($0, /[[:space:]]+#/);
      if (cpos > 0) {
        body = substr($0, 1, cpos - 1);
        cmt = substr($0, cpos);
      } else {
        body = $0;
        cmt = "";
      }
      sub(/[[:space:]]+$/, "", body);
      q = "";
      if (body ~ /["'\'']$/) {
        q = substr(body, length(body), 1);
        body = substr(body, 1, length(body) - 1);
      }
      if (body !~ /,no-resolve$/) {
        print body ",no-resolve" q cmt;
      } else {
        print $0;
      }
      next;
    }
    { print $0 }
  ' "$_cfg" > "$_out_cfg"
}

restore_cn_ip_rules() {
  local _cfg="$1"
  local _orig_file="$2"
  local _out_cfg="$3"

  [ -s "$_orig_file" ] || { cp -f "$_cfg" "$_out_cfg"; return 0; }

  $AWK -v ofile="$_orig_file" '
    function norm_cn(s,    cpos, body, q) {
      cpos = match(s, /[[:space:]]+#/);
      body = (cpos > 0) ? substr(s, 1, cpos - 1) : s;
      sub(/[[:space:]]+$/, "", body);
      q = "";
      if (body ~ /["'\'']$/) {
        q = substr(body, length(body), 1);
        body = substr(body, 1, length(body) - 1);
      }
      sub(/,no-resolve$/, "", body);
      return body q;
    }
    BEGIN {
      while ((getline oline < ofile) > 0) {
        tpos = index(oline, "\t");
        if (tpos > 0) {
          idx = substr(oline, 1, tpos - 1);
          raw = substr(oline, tpos + 1);
          key = idx "\t" norm_cn(raw);
          orig[key] = raw;
        }
      }
      close(ofile);
    }
    /^[[:space:]]*-[[:space:]]*["'\'']?RULE-SET,CN_IP,/ {
      b = norm_cn($0);
      cnt[b]++;
      k = cnt[b] "\t" b;
      if (k in orig) {
        print orig[k];
      } else {
        print $0;
      }
      next;
    }
    { print $0 }
  ' "$_cfg" > "$_out_cfg"
}

validate_config_file() {
  local _cfg="$1"
  [ -s "$_cfg" ] || return 1

  local _psn_count=""
  _psn_count=$($AWK '
    BEGIN { in_dns = 0; c = 0 }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    /^[^[:space:]#]/ { in_dns = ($0 ~ /^dns:[[:space:]]*(#.*)?$/); next }
    in_dns && /^[[:space:]]*proxy-server-nameserver:[[:space:]]*(\[.*\])?[[:space:]]*(#.*)?$/ { c++ }
    END { print c }
  ' "$_cfg")
  if [ "${_psn_count:-0}" -gt 1 ]; then
    print_out "[!] 配置校验异常: 检测到 ${_psn_count} 个 proxy-server-nameserver 定义"
    return 1
  fi

  if [ -n "$BOX_BIN" ]; then
    local _check_out="" _rc=0
    _check_out=$("$BOX_BIN" -t -d "$CLASH_DIR" -f "$_cfg" 2>&1)
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
      print_out "[!] Clash 核心配置校验失败 (rc=${_rc}):"
      print_out "$_check_out"
      return 1
    fi
  fi
  return 0
}

# Real DNS-over-TCP wire query verifying server sends back DNS response header (Transaction ID 0x1234)
probe_dns_tcp_wire() {
  local _ip="$1" _port="$2" _hex=""
  [ -n "$BUSYBOX" ] || return 1
  if [ "$CAN_SETUIDGID" = "1" ]; then
    if [ -n "$TIMEOUT_BIN" ]; then
      _hex=$($BUSYBOX printf '\x00\x18\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x02qq\x03com\x00\x00\x01\x00\x01' | $TIMEOUT_BIN 3 $SETUIDGID 0:3005 $NC "$_ip" "$_port" 2>/dev/null | $BUSYBOX dd bs=1 count=14 2>/dev/null | $BUSYBOX od -An -tx1 2>/dev/null | tr '\n' ' ')
    else
      _hex=$($BUSYBOX printf '\x00\x18\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x02qq\x03com\x00\x00\x01\x00\x01' | $SETUIDGID 0:3005 $NC "$_ip" "$_port" 2>/dev/null | $BUSYBOX dd bs=1 count=14 2>/dev/null | $BUSYBOX od -An -tx1 2>/dev/null | tr '\n' ' ')
    fi
  else
    if [ -n "$TIMEOUT_BIN" ]; then
      _hex=$($BUSYBOX printf '\x00\x18\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x02qq\x03com\x00\x00\x01\x00\x01' | $TIMEOUT_BIN 3 $NC "$_ip" "$_port" 2>/dev/null | $BUSYBOX dd bs=1 count=14 2>/dev/null | $BUSYBOX od -An -tx1 2>/dev/null | tr '\n' ' ')
    else
      _hex=$($BUSYBOX printf '\x00\x18\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x02qq\x03com\x00\x00\x01\x00\x01' | $NC "$_ip" "$_port" 2>/dev/null | $BUSYBOX dd bs=1 count=14 2>/dev/null | $BUSYBOX od -An -tx1 2>/dev/null | tr '\n' ' ')
    fi
  fi
  case "$_hex" in
    *"12 34"*) return 0 ;;
  esac
  return 1
}

# Check true WAN reachability via real DNS/HTTPS payload exchange (never spoofed by Clash local SYN accept)
has_online_network() {
  local _out="" _ip="" _json=""
  if [ "$CAN_SETUIDGID" = "1" ]; then
    _out=$(run_nslookup_timeout 3 1 qq.com 223.5.5.5)
    _ip=$(printf '%s\n' "$_out" | parse_nslookup_ipv4 | pick_first_usable_ipv4)
    [ -n "$_ip" ] && return 0
  fi

  if [ -n "$CURL" ]; then
    _json=$("$CURL" -sS --max-time 3 -H "Accept: application/dns-json" "https://223.5.5.5/resolve?name=qq.com&type=1" 2>/dev/null)
    if printf '%s' "$_json" | grep -q '"Answer"'; then
      return 0
    fi
  fi

  _out=$(run_nslookup_timeout 3 0 qq.com 223.5.5.5)
  _ip=$(printf '%s\n' "$_out" | parse_nslookup_ipv4 | pick_first_usable_ipv4)
  [ -n "$_ip" ] && return 0

  probe_dns_tcp_wire 223.5.5.5 53 && return 0
  return 1
}

probe_dns_live() {
  local _first_url="" _hp="" _host="" _port="" _probe_ip="" _domain="" _res="" _resolved_ip="" _try=0
  PROBE_MSG="未知解析状态"

  _first_url=$(printf '%s\n' "$TARGET_DNS_LIST" | head -n 1)
  if [ -z "$_first_url" ]; then
    PROBE_MSG="目标 DNS 列表为空"
    return 1
  fi

  _hp="${_first_url#tcp://}"
  _host="${_hp%%:*}"
  _port="${_hp##*:}"
  [ -z "$_port" ] && _port="8080"

  if is_valid_ipv4 "$_host"; then
    _probe_ip="$_host"
  else
    _probe_ip=$(resolve_host_to_ip "$_host") || {
      PROBE_MSG="无法解析专用 DNS 域名 ${_host}"
      return 1
    }
  fi

  _domain=$(extract_test_entry_domain)
  [ -z "$_domain" ] && _domain="example.com"

  for _try in 1 2; do
    _res=$(run_nslookup_timeout 4 "$CAN_SETUIDGID" "$_domain" "${_probe_ip}:${_port}")
    _resolved_ip=$(printf '%s\n' "$_res" | parse_nslookup_ipv4 | pick_first_usable_ipv4)
    if [ -n "$_resolved_ip" ]; then
      PROBE_MSG="入口 ${_domain} -> ${_resolved_ip} (经 ${_probe_ip}:${_port})"
      return 0
    fi
    sleep 1
  done

  if probe_dns_tcp_wire "$_probe_ip" "$_port"; then
    PROBE_MSG="专用 DNS-over-TCP (${_probe_ip}:${_port}) 协议握手正常"
    return 0
  fi

  PROBE_MSG="专用 DNS (${_probe_ip}:${_port}) 无法连通或解析超时"
  return 1
}

copy_file_preserve_meta() {
  local _src="$1" _dst="$2" _owner=""
  if [ -e "$_dst" ]; then
    _owner=$(stat -c '%u:%g' "$_dst" 2>/dev/null || true)
  fi
  cp -f "$_src" "$_dst"
  chmod 0644 "$_dst"
  if [ -n "$_owner" ]; then
    chown "$_owner" "$_dst" 2>/dev/null || true
  else
    chown 0:3005 "$_dst" 2>/dev/null || true
  fi
}

parse_controller_info() {
  # Sets API_HOST, API_PORT, API_SECRET
  API_HOST="127.0.0.1"
  API_PORT="9090"
  API_SECRET=""
  [ -f "$CLASH_CONFIG" ] || return 1

  local _ctrl=""
  _ctrl=$($AWK '
    /^[[:space:]]*external-controller:/ {
      v=$0; sub(/^[^:]*:[[:space:]]*/, "", v);
      sub(/[[:space:]]+#.*$/, "", v); gsub(/["'\''[:space:]]/, "", v);
      print v; exit
    }' "$CLASH_CONFIG")
  if [ -n "$_ctrl" ]; then
    case "$_ctrl" in
      *:*)
        API_PORT="${_ctrl##*:}"
        API_HOST="${_ctrl%:*}"
        ;;
      *)
        API_PORT="$_ctrl"
        API_HOST="127.0.0.1"
        ;;
    esac
    case "$API_HOST" in
      ""|"0.0.0.0"|"[::]"|"::") API_HOST="127.0.0.1" ;;
    esac
  fi

  API_SECRET=$($AWK '
    /^[[:space:]]*secret:/ {
      v=$0; sub(/^[^:]*:[[:space:]]*/, "", v);
      sub(/[[:space:]]+#.*$/, "", v); gsub(/^["'\'']|["'\'']$/, "", v);
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v);
      print v; exit
    }' "$CLASH_CONFIG")
}

reload_surfing_if_running() {
  local _pid=""
  for _p in "$BOX_BIN_NAME" clash mihomo; do
    [ -z "$_p" ] && continue
    _pid=$(pidof "$_p" 2>/dev/null || true)
    [ -n "$_pid" ] && break
  done
  [ -z "$_pid" ] && return 0

  # Try hot reload via Clash REST API first (no traffic interruption)
  if [ -n "$CURL" ] && [ -f "$CLASH_CONFIG" ]; then
    parse_controller_info
    if [ -n "$API_PORT" ] && [ "$API_PORT" -gt 0 ] 2>/dev/null; then
      local _http_code=""
      if [ -n "$API_SECRET" ]; then
        _http_code=$("$CURL" -s -o /dev/null -w "%{http_code}" --max-time 5 -X PUT \
          "http://${API_HOST}:${API_PORT}/configs?force=true" \
          -H "Authorization: Bearer ${API_SECRET}" \
          -H "Content-Type: application/json" \
          -d "{\"path\":\"${CLASH_CONFIG}\"}" 2>/dev/null)
      else
        _http_code=$("$CURL" -s -o /dev/null -w "%{http_code}" --max-time 5 -X PUT \
          "http://${API_HOST}:${API_PORT}/configs?force=true" \
          -H "Content-Type: application/json" \
          -d "{\"path\":\"${CLASH_CONFIG}\"}" 2>/dev/null)
      fi
      if [ "$_http_code" = "204" ] || [ "$_http_code" = "200" ]; then
        log_msg "Surfing core hot-reloaded via ${API_HOST}:${API_PORT}"
        return 0
      fi
    fi
  fi

  # Fallback: restart box.service cleanly
  if [ -x "${SURFING_SCRIPTS}/box.service" ]; then
    "${SURFING_SCRIPTS}/box.service" restart >> "$LOG_FILE" 2>&1
    if [ -x "${SURFING_SCRIPTS}/box.iptables" ]; then
      "${SURFING_SCRIPTS}/box.iptables" renew >> "$LOG_FILE" 2>&1 || true
    fi
    log_msg "Surfing restarted via box.service"
  fi
}

cleanup_unapplied_backups() {
  local _was_applied="$1"
  if [ "$_was_applied" != "1" ]; then
    rm -f "$BACKUP_PSN" "$BACKUP_PSN_META" "$BACKUP_CN_IP"
  fi
}

apply_dns_fix() {
  local _reason="${1:-manual}"
  local _own_lock=0
  if [ "$LOCK_HELD" != "1" ]; then
    acquire_lock || { print_out "[!] 获取操作锁超时"; return 1; }
    _own_lock=1
  fi

  local _pid_tag="$$"
  local _tmp_block="${DATA_DIR}/psn_new.${_pid_tag}.tmp"
  local _tmp_cur="${DATA_DIR}/psn_cur.${_pid_tag}.tmp"
  local _tmp_cfg1="${DATA_DIR}/cfg1.${_pid_tag}.tmp"
  local _tmp_cfg2="${DATA_DIR}/cfg2.${_pid_tag}.tmp"
  local _pre_edit="${DATA_DIR}/config.yaml.pre_edit.${_pid_tag}"
  local _was_applied="$APPLIED"

  _cleanup_apply_tmp() {
    rm -f "$_tmp_block" "$_tmp_cur" "$_tmp_cfg1" "$_tmp_cfg2" "$_pre_edit"
    [ "$_own_lock" -eq 1 ] && release_lock
  }

  if [ ! -f "$CLASH_CONFIG" ]; then
    print_out "[!] 未找到 Surfing 配置文件: ${CLASH_CONFIG}"
    _cleanup_apply_tmp
    return 1
  fi

  if ! build_target_dns_entries; then
    print_out "[!] 未能从 ${PROXIES_DIR}/*.yaml 提取到机场 tcp:// 抗污染 DNS"
    _cleanup_apply_tmp
    return 1
  fi

  print_out "[*] DNS 解析摘要: ${RESOLVE_SUMMARY}"

  # Save precision block backup only before modifying an unpatched config
  if [ "$_was_applied" != "1" ] || [ ! -f "$BACKUP_PSN_META" ]; then
    capture_precision_backup "$CLASH_CONFIG" || {
      print_out "[!] 备份原有配置失败"
      _cleanup_apply_tmp
      return 1
    }
  fi
  cp -f "$CLASH_CONFIG" "$_pre_edit"

  local _info="" _had="" _s="" _e="" _ind="" _ins="" _src_orig_block=""
  _info=$(inspect_psn_block "$CLASH_CONFIG")
  set -- $_info
  _had="$1"; _s="$2"; _e="$3"; _ind="$4"; _ins="$5"

  if [ "$_was_applied" != "1" ]; then
    _src_orig_block="$BACKUP_PSN"
  else
    if [ "$_had" = "1" ] && [ "$_s" -gt 0 ] && [ "$_e" -ge "$_s" ]; then
      $SED -n "${_s},${_e}p" "$CLASH_CONFIG" > "$_tmp_cur"
    else
      : > "$_tmp_cur"
    fi
    _src_orig_block="$_tmp_cur"
  fi

  generate_psn_block_file "$_src_orig_block" "$_ind" "$_tmp_block" "$LAST_APPLIED_DNS"

  if ! splice_psn_block "$CLASH_CONFIG" "$_tmp_block" "$_tmp_cfg1"; then
    print_out "[!] 插入 proxy-server-nameserver 区块失败"
    cleanup_unapplied_backups "$_was_applied"
    _cleanup_apply_tmp
    return 1
  fi

  if [ "$ADD_CN_IP_NORESOLVE" = "1" ]; then
    apply_cn_ip_no_resolve "$_tmp_cfg1" "$_tmp_cfg2"
  else
    cp -f "$_tmp_cfg1" "$_tmp_cfg2"
  fi

  local _first_target=""
  _first_target=$(printf '%s\n' "$TARGET_DNS_LIST" | head -n 1)
  if ! grep -qF -- "- ${_first_target}" "$_tmp_cfg2"; then
    print_out "[!] 写入自检失败: 新配置中未找到 - ${_first_target}"
    cleanup_unapplied_backups "$_was_applied"
    _cleanup_apply_tmp
    return 1
  fi

  if [ "$ADD_CN_IP_NORESOLVE" = "1" ] && grep -Eq '^[[:space:]]*-[[:space:]]*["'\'']?RULE-SET,CN_IP,' "$_tmp_cfg2"; then
    if grep -q ",no-resolve,no-resolve" "$_tmp_cfg2"; then
      print_out "[!] 写入自检失败: 检测到重复 ,no-resolve"
      cleanup_unapplied_backups "$_was_applied"
      _cleanup_apply_tmp
      return 1
    fi
  fi

  if ! validate_config_file "$_tmp_cfg2"; then
    print_out "[!] 核心校验未通过，保持原有配置不变"
    cleanup_unapplied_backups "$_was_applied"
    _cleanup_apply_tmp
    return 1
  fi

  copy_file_preserve_meta "$_tmp_cfg2" "$CLASH_CONFIG"

  # Live DNS resolution check when truly online; auto-rollback if unreachable
  if has_online_network; then
    if probe_dns_live; then
      print_out "[+] 实测解析校验通过: ${PROBE_MSG}"
    else
      print_out "[!] 实测解析失败 (${PROBE_MSG})，自动回滚到原有备份！"
      copy_file_preserve_meta "$_pre_edit" "$CLASH_CONFIG"
      cleanup_unapplied_backups "$_was_applied"
      LAST_STATUS="rollback_probe_failed"
      save_state
      _cleanup_apply_tmp
      return 1
    fi
  else
    print_out "[!] 当前无公网连接，跳过在线解析测试（本地结构与核心校验已通过）"
  fi

  APPLIED="1"
  LAST_APPLIED_DNS=$(printf '%s' "$TARGET_DNS_LIST" | tr '\n' ',' | $SED 's/,$//')
  NO_RESOLVE_APPLIED="$ADD_CN_IP_NORESOLVE"
  LAST_STATUS="applied_${_reason}"
  save_state

  print_out "[+] 当前生效 proxy-server-nameserver:"
  local _pinfo="" _pl="" _cl=""
  _pinfo=$(inspect_psn_block "$CLASH_CONFIG")
  set -- $_pinfo
  if [ "$1" = "1" ] && [ "$2" -gt 0 ] && [ "$3" -ge "$2" ]; then
    $SED -n "${2},${3}p" "$CLASH_CONFIG" | while IFS= read -r _pl; do
      print_out "    $_pl"
    done
  fi
  if [ "$ADD_CN_IP_NORESOLVE" = "1" ]; then
    grep -E '^[[:space:]]*-[[:space:]]*["'\'']?RULE-SET,CN_IP,' "$CLASH_CONFIG" | while IFS= read -r _cl; do
      print_out "[+] CN_IP 规则: ${_cl}"
    done
  fi

  reload_surfing_if_running
  _cleanup_apply_tmp
  return 0
}

restore_precision_backup() {
  local _reason="${1:-restore}"
  local _own_lock=0
  if [ "$LOCK_HELD" != "1" ]; then
    acquire_lock || { log_msg "Failed to acquire lock for restore (${_reason})"; return 1; }
    _own_lock=1
  fi

  if [ ! -f "$CLASH_CONFIG" ]; then
    APPLIED="0"
    LAST_STATUS="no_config_${_reason}"
    save_state
    [ "$_own_lock" -eq 1 ] && release_lock
    return 0
  fi

  if [ ! -f "$BACKUP_PSN_META" ] && [ ! -f "$BACKUP_PSN" ] && [ ! -f "$BACKUP_CN_IP" ]; then
    log_msg "No precision backup blocks to restore (${_reason})"
    APPLIED="0"
    LAST_STATUS="clean_${_reason}"
    save_state
    [ "$_own_lock" -eq 1 ] && release_lock
    return 0
  fi

  local _pid_tag="$$"
  local _had_orig="1"
  local _tmp_r1="${DATA_DIR}/restore1.${_pid_tag}.tmp"
  local _tmp_r2="${DATA_DIR}/restore2.${_pid_tag}.tmp"
  [ -f "$BACKUP_PSN_META" ] && _had_orig=$($SED -n 's/^ORIGINAL_HAD_BLOCK=//p' "$BACKUP_PSN_META" | head -n 1)

  if [ "$_had_orig" = "1" ] && [ -s "$BACKUP_PSN" ]; then
    if ! splice_psn_block "$CLASH_CONFIG" "$BACKUP_PSN" "$_tmp_r1"; then
      cp -f "$CLASH_CONFIG" "$_tmp_r1"
    fi
  elif [ "$_had_orig" = "0" ]; then
    delete_psn_block "$CLASH_CONFIG" "$_tmp_r1"
  else
    cp -f "$CLASH_CONFIG" "$_tmp_r1"
  fi

  if [ "$NO_RESOLVE_APPLIED" = "1" ] && [ -s "$BACKUP_CN_IP" ]; then
    restore_cn_ip_rules "$_tmp_r1" "$BACKUP_CN_IP" "$_tmp_r2"
  else
    cp -f "$_tmp_r1" "$_tmp_r2"
  fi

  if validate_config_file "$_tmp_r2"; then
    copy_file_preserve_meta "$_tmp_r2" "$CLASH_CONFIG"
    rm -f "$_tmp_r1" "$_tmp_r2" "$BACKUP_PSN" "$BACKUP_PSN_META" "$BACKUP_CN_IP"
    APPLIED="0"
    LAST_APPLIED_DNS=""
    NO_RESOLVE_APPLIED="0"
    LAST_STATUS="restored_${_reason}"
    save_state
    log_msg "Precision restore succeeded (${_reason})"
    reload_surfing_if_running
    [ "$_own_lock" -eq 1 ] && release_lock
    return 0
  else
    rm -f "$_tmp_r1" "$_tmp_r2"
    log_msg "Precision restore validation failed (${_reason})"
    [ "$_own_lock" -eq 1 ] && release_lock
    return 1
  fi
}

start_module_inotifyd() {
  local _moddir="$1"
  local _script="${_moddir}/common/inotify.sh"
  [ -x "$_script" ] || chmod 0755 "$_script" 2>/dev/null || true

  if [ -n "$PKILL" ]; then
    $PKILL -f "inotifyd ${_script}" >/dev/null 2>&1 || true
  fi
  short_sleep
  if [ -n "$SETSID" ] && $SETSID true >/dev/null 2>&1; then
    $SETSID $INOTIFYD "$_script" "$_moddir:d,n" </dev/null >/dev/null 2>&1 &
  elif command -v nohup >/dev/null 2>&1; then
    nohup $INOTIFYD "$_script" "$_moddir:d,n" </dev/null >/dev/null 2>&1 &
  else
    $INOTIFYD "$_script" "$_moddir:d,n" </dev/null >/dev/null 2>&1 &
  fi
  log_msg "Started inotifyd watcher on ${_moddir}"
}

stop_module_inotifyd() {
  local _moddir="$1"
  local _script="${_moddir}/common/inotify.sh"
  if [ -n "$PKILL" ]; then
    $PKILL -f "inotifyd ${_script}" >/dev/null 2>&1 || true
  fi
}

BASE_DESC="Extract official ikuuu anti-pollution DNS into Surfing config.yaml with precision block backup, instant disable/uninstall restore, CN_IP no-resolve, and AGH compatibility."

set_prop_description() {
  local _prop="$1" _desc="$2"
  [ -f "$_prop" ] || return 0
  NEW_DESC="$_desc" $AWK '
    BEGIN { d = ENVIRON["NEW_DESC"]; done = 0 }
    /^description=/ { print "description=" d; done = 1; next }
    { print $0 }
    END { if (!done) print "description=" d }
  ' "$_prop" > "${_prop}.tmp.$$" && mv -f "${_prop}.tmp.$$" "$_prop"
  chmod 0644 "$_prop" 2>/dev/null || true
}

update_module_desc() {
  # Args: <moddir> <pending_reboot|active|disabled|error>
  local _moddir="$1" _mode="$2" _desc=""
  case "$_mode" in
    pending_reboot)
      if [ -f "${_moddir}/disable" ] || [ -f "${LIVE_MOD_DIR}/disable" ]; then
        _desc="（等待重启中 | 已禁用）${BASE_DESC}"
      elif [ -n "$LAST_APPLIED_DNS" ]; then
        _desc="（等待重启中 | 已写入 ${LAST_APPLIED_DNS}）${BASE_DESC}"
      else
        _desc="（等待重启中）${BASE_DESC}"
      fi
      ;;
    active)
      if [ "$APPLIED" = "1" ] && [ -n "$LAST_APPLIED_DNS" ]; then
        _desc="[运行中 | ${LAST_APPLIED_DNS}] ${BASE_DESC}"
      else
        _desc="[未应用 | 点击操作检查或修复] ${BASE_DESC}"
      fi
      ;;
    disabled)
      _desc="[已停用 | 已精准还原原有配置] ${BASE_DESC}"
      ;;
    *)
      _desc="[异常 | 点击操作查看诊断] ${BASE_DESC}"
      ;;
  esac

  set_prop_description "${_moddir}/module.prop" "$_desc"
  if [ -n "$LIVE_MOD_DIR" ] && [ "$LIVE_MOD_DIR" != "$_moddir" ] && [ -f "${LIVE_MOD_DIR}/module.prop" ]; then
    set_prop_description "${LIVE_MOD_DIR}/module.prop" "$_desc"
  fi

  if [ -x /data/adb/ksud ] && /data/adb/ksud module config --help >/dev/null 2>&1; then
    KSU_MODULE="$MOD_ID" MODULE_ID="$MOD_ID" /data/adb/ksud module config set override.description "$_desc" >/dev/null 2>&1 || true
  elif [ -x /data/adb/apd ] && /data/adb/apd module config --help >/dev/null 2>&1; then
    MODULE_ID="$MOD_ID" /data/adb/apd module config set override.description "$_desc" >/dev/null 2>&1 || true
  fi
}
