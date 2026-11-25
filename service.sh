#!/system/bin/sh
# Boot service for fix_Surfing_Dns_ikuuu (Magisk / KernelSU / APatch)

_self_dir=$(dirname "$0" 2>/dev/null || echo ".")
MODDIR=$(CDPATH= cd -- "$_self_dir" && pwd)
[ -f "${MODDIR}/common/dns_lib.sh" ] || exit 0
. "${MODDIR}/common/dns_lib.sh"
init_env

if [ -f "${MODDIR}/disable" ] || [ -f "${MODDIR}/remove" ]; then
  exit 0
fi

# Always ensure real-time disable/remove listener is active
start_module_inotifyd "$MODDIR"
update_module_desc "$MODDIR" "active"

if [ "$APPLIED" != "1" ] || [ "$AUTO_BOOT_SYNC" = "1" ] ||
   [ "$AGH_FIX_ENABLED" = "1" ] || agh_has_changes; then
  (
    _wait=0
    while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ "$_wait" -lt 60 ]; do
      sleep 2
      _wait=$((_wait + 1))
    done

    # Wait up to 30s for WAN connectivity after boot
    _net_wait=0
    while ! has_online_network && [ "$_net_wait" -lt 15 ]; do
      sleep 2
      _net_wait=$((_net_wait + 1))
    done

    [ -f "${MODDIR}/disable" ] && exit 0
    [ -f "${MODDIR}/remove" ] && exit 0

    init_env
    # Root modules start concurrently: wait for the core and its capture chain,
    # not by repeatedly applying a repair while dependencies are unavailable.
    if [ "$AGH_FIX_ENABLED" = 1 ]; then
      _agh_start_wait=0
      while ! pidof "$BOX_BIN_NAME" >/dev/null 2>&1 ||
            ! iptables -t mangle -S BOX_LOCAL >/dev/null 2>&1; do
        [ "$_agh_start_wait" -ge 15 ] && break
        [ -f "${MODDIR}/disable" ] && exit 0
        [ -f "${MODDIR}/remove" ] && exit 0
        sleep 2
        _agh_start_wait=$((_agh_start_wait+1))
      done
    fi
    # An attempted DNS transaction already coordinates AGH or its rollback.
    # Do not run another repair immediately after that transaction fails.
    _dns_attempted=0
    if [ "$APPLIED" != "1" ]; then
      log_msg "Boot sync: module enabled while APPLIED=0, applying DNS fix..."
      _dns_attempted=1
      if ! apply_dns_fix "boot_reenable" >/dev/null 2>&1; then
        log_msg "Boot application failed; recovery records preserved"
      fi
      update_module_desc "$MODDIR" "active"
    elif [ "$AUTO_BOOT_SYNC" = "1" ]; then
      if build_target_dns_entries; then
        _skip_dns_sync=0
        _cur_psn=$(get_active_psn_entries "$CLASH_CONFIG" | head -n 1)
        _first_target=$(printf '%s\n' "$TARGET_DNS_LIST" | head -n 1)
        _want=$(printf '%s' "$TARGET_DNS_LIST" | tr '\n' ',' | $SED 's/,$//')

        # If IP mode fell back to domain due to offline boot while a valid public IP is already configured, skip overwrite
        if [ "$DNS_WRITE_MODE" = "ip" ] && [ "$USED_DOMAIN_FALLBACK" = "1" ]; then
          _cur_host="${_cur_psn#tcp://}"
          _cur_host="${_cur_host%%:*}"
          if is_usable_public_ipv4 "$_cur_host"; then
            _skip_dns_sync=1
          fi
        fi

        _need=0
        [ "$_want" != "$LAST_APPLIED_DNS" ] && _need=1
        [ "$_cur_psn" != "$_first_target" ] && _need=1
        if [ "$ADD_CN_IP_NORESOLVE" = "1" ]; then
          _cn_missing=$($AWK '
            /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
            /^[[:space:]]*-[[:space:]]*["'\'']?RULE-SET,CN_IP,/ {
              cpos = match($0, /[[:space:]]+#/);
              body = (cpos > 0) ? substr($0, 1, cpos - 1) : $0;
              sub(/[[:space:]]+$/, "", body);
              if (body !~ /,no-resolve["'\'']?$/) { found = 1; exit }
            }
            END { print found + 0 }
          ' "$CLASH_CONFIG" 2>/dev/null)
          [ "${_cn_missing:-0}" -eq 1 ] && _need=1
        fi

        if [ "$_skip_dns_sync" -eq 0 ] && [ "$_need" -eq 1 ]; then
          log_msg "Boot sync: config drift detected, re-applying DNS fix..."
          _dns_attempted=1
          if ! apply_dns_fix "boot_sync" >/dev/null 2>&1; then
            log_msg "Boot DNS sync failed; recovery records preserved"
          fi
          update_module_desc "$MODDIR" "active"
        fi
      fi
    fi
    # AGH launch identity can drift independently of the subscription/PSN.
    if [ "$_dns_attempted" -eq 0 ]; then
      if ! sync_agh_fix "boot"; then
        log_msg "Boot AGH coordination failed ($AGH_STATUS); backups preserved"
      fi
    fi
  ) &
fi
