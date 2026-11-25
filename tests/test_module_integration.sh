#!/bin/sh
# Exercise the shared module transactions with private fixtures and mocked I/O.
# Never call the real init_env: every path and callback stays under TEST_TMP.
set -eu

TEST_REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/module-integration-tests.XXXXXX")
TEST_COUNT=0

cleanup() {
  case "$TEST_TMP" in
    "${TMPDIR:-/tmp}"/module-integration-tests.??????) ;;
    *) printf 'Refusing to clean an unexpected fixture path: %s\n' "$TEST_TMP" >&2; return 1 ;;
  esac
  if [ -d "$TEST_TMP/installer-data" ]; then
    for fixture in "$TEST_TMP/installer-data"/* "$TEST_TMP/installer-data"/.[!.]*; do
      [ -f "$fixture" ] || continue
      rm -f -- "$fixture"
    done
    rmdir -- "$TEST_TMP/installer-data"
  fi
  if [ -d "$TEST_TMP/installer-module" ]; then
    rm -f -- "$TEST_TMP/installer-module/common/dns_lib.sh"
    rmdir -- "$TEST_TMP/installer-module/common" "$TEST_TMP/installer-module"
  fi
  for fixture in "$TEST_TMP"/* "$TEST_TMP"/.[!.]*; do
    [ -f "$fixture" ] || continue
    rm -f -- "$fixture"
  done
  rmdir -- "$TEST_TMP"
}
trap cleanup 0

ok() { TEST_COUNT=$((TEST_COUNT + 1)); printf 'ok %s - %s\n' "$TEST_COUNT" "$1"; }
fail() { TEST_COUNT=$((TEST_COUNT + 1)); printf 'not ok %s - %s\n' "$TEST_COUNT" "$1" >&2; exit 1; }
expect_success() { description=$1; shift; if "$@"; then ok "$description"; else fail "$description"; fi; }
expect_failure() { description=$1; shift; if "$@"; then fail "$description"; else ok "$description"; fi; }
assert_equal() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (expected: $2; actual: $3)"; fi; }
assert_file_equal() { if cmp -s "$2" "$3"; then ok "$1"; else fail "$1"; fi; }
write_fixture() { printf '%s\n' "$2" > "$1"; }

MODDIR=$TEST_REPO
. "$TEST_REPO/common/dns_lib.sh"
. "$TEST_REPO/common/agh_fix.sh"

# Test the real metadata-copy helper before replacing it for transaction tests.
# Existing target metadata is readable; only the missing source makes cp fail.
write_fixture "$TEST_TMP/copy.target" 'keep this original content'
cp -f "$TEST_TMP/copy.target" "$TEST_TMP/copy.expected"
if stat -c '%u:%g' "$TEST_TMP/copy.target" >/dev/null; then
  ok 'copy-test target metadata is readable'
else
  fail 'copy-test target metadata is readable'
fi
if copy_file_preserve_meta "$TEST_TMP/missing.source" "$TEST_TMP/copy.target" 2> "$TEST_TMP/copy.stderr"; then
  fail 'metadata-copy helper surfaces a failed cp'
else
  ok 'metadata-copy helper surfaces a failed cp'
fi
assert_file_equal 'failed cp does not replace the target content' "$TEST_TMP/copy.expected" "$TEST_TMP/copy.target"

AWK=${AWK:-awk}
SED=${SED:-sed}
DATA_DIR=$TEST_TMP
BACKUP_DIR=$TEST_TMP
CLASH_CONFIG=$TEST_TMP/config.yaml
BACKUP_FULL=$TEST_TMP/config.yaml.pre_module
BACKUP_PSN=$TEST_TMP/proxy_server_nameserver.orig
BACKUP_PSN_META=$TEST_TMP/psn_meta.conf
BACKUP_CN_IP=$TEST_TMP/cn_ip_rule.orig
STATE_FILE=$TEST_TMP/state.conf
LOG_FILE=$TEST_TMP/module.log
LIVE_MOD_DIR=$TEST_TMP

log_msg() { printf '%s\n' "$1" >> "$LOG_FILE"; }
print_out() { log_msg "$1"; }
acquire_lock() {
  LOCK_HELD=1
  if [ "$MOCK_DISABLE_DURING_ACQUIRE" = 1 ]; then
    : > "$LIVE_MOD_DIR/disable"
    cp -f "$TEST_TMP/state.disabled_expected" "$STATE_FILE" || return 1
  fi
  return 0
}
release_lock() { LOCK_HELD=0; }
copy_file_preserve_meta() { cp -f "$1" "$2"; }
validate_config_file() { [ -s "$1" ]; }
has_online_network() { return 1; }
build_target_dns_entries() {
  MOCK_BUILD_CALLS=$((MOCK_BUILD_CALLS + 1))
  TARGET_DNS_LIST=$MOCK_TARGET_DNS
  RESOLVE_SUMMARY='fixture DNS'
  return 0
}
reload_surfing_if_running() {
  MOCK_RELOAD_CALLS=$((MOCK_RELOAD_CALLS + 1))
  [ "$MOCK_RELOAD_CALLS" -ne "$MOCK_FAIL_RELOAD_CALL" ]
}
save_state() {
  printf 'APPLIED=%s\nLAST_APPLIED_DNS=%s\nNO_RESOLVE_APPLIED=%s\nLAST_STATUS=%s\nAGH_APPLIED=%s\nAGH_STATUS=%s\n' \
    "$APPLIED" "$LAST_APPLIED_DNS" "$NO_RESOLVE_APPLIED" "$LAST_STATUS" "$AGH_APPLIED" "$AGH_STATUS" > "$STATE_FILE"
}
sync_agh_fix() {
  MOCK_SYNC_CALLS=$((MOCK_SYNC_CALLS + 1))
  case "$MOCK_SYNC_RESULT" in
    success) AGH_STATUS=active; AGH_APPLIED=1; save_state; return 0 ;;
    ordinary_failure) AGH_STATUS=apply_failed_rolled_back; AGH_APPLIED=0; save_state; return 1 ;;
    rollback_failure) AGH_STATUS=rollback_failed; AGH_APPLIED=1; save_state; return 1 ;;
    *) return 1 ;;
  esac
}
restore_agh_fix() {
  MOCK_AGH_RESTORE_CALLS=$((MOCK_AGH_RESTORE_CALLS + 1))
  AGH_APPLIED=0
  AGH_STATUS=inactive
  save_state
  return 0
}

reset_case() {
  write_fixture "$CLASH_CONFIG" 'mode: Rule
dns:
  enable: true
  proxy-server-nameserver:
    - https://1.12.12.12/dns-query
  nameserver:
    - 127.0.0.1:51248
rules:
  - RULE-SET,CN_IP,DIRECT
  - MATCH,PROXY'
  cp -f "$CLASH_CONFIG" "$TEST_TMP/config.original"
  rm -f "$BACKUP_FULL" "$BACKUP_PSN" "$BACKUP_PSN_META" "$BACKUP_CN_IP" "$STATE_FILE"
  rm -f "$LIVE_MOD_DIR/disable" "$LIVE_MOD_DIR/remove"
  rm -f "$DATA_DIR/psn_new.$$.tmp" "$DATA_DIR/psn_cur.$$.tmp" \
    "$DATA_DIR/cfg1.$$.tmp" "$DATA_DIR/cfg2.$$.tmp" "$DATA_DIR/config.yaml.pre_edit.$$" \
    "$DATA_DIR/restore1.$$.tmp" "$DATA_DIR/restore2.$$.tmp"
  : > "$LOG_FILE"
  APPLIED=0
  LAST_APPLIED_DNS=''
  NO_RESOLVE_APPLIED=0
  LAST_STATUS=init
  AGH_APPLIED=0
  AGH_STATUS=inactive
  ADD_CN_IP_NORESOLVE=1
  REPLACE_MODE=replace
  LOCK_HELD=0
  MOCK_TARGET_DNS=tcp://47.105.116.11:8080
  MOCK_RELOAD_CALLS=0
  MOCK_FAIL_RELOAD_CALL=0
  MOCK_SYNC_CALLS=0
  MOCK_SYNC_RESULT=success
  MOCK_AGH_RESTORE_CALLS=0
  MOCK_BUILD_CALLS=0
  MOCK_DISABLE_DURING_ACQUIRE=0
}

# The normal route exercises actual PSN and CN-IP editing and restoration.
reset_case
expect_success 'normal module application succeeds' apply_dns_fix manual
assert_equal 'normal module application updates node DNS' tcp://47.105.116.11:8080 "$(get_active_psn_entries "$CLASH_CONFIG")"
expect_success 'normal module application adds CN no-resolve' grep -qF 'RULE-SET,CN_IP,DIRECT,no-resolve' "$CLASH_CONFIG"
assert_equal 'normal application records applied state' 1 "$APPLIED"
assert_equal 'normal application reaches the AGH coordinator' 1 "$MOCK_SYNC_CALLS"
expect_success 'normal module restoration succeeds' restore_precision_backup disable
assert_file_equal 'normal apply and restore round-trip the original config' "$TEST_TMP/config.original" "$CLASH_CONFIG"
assert_equal 'normal restoration calls AGH restore first' 1 "$MOCK_AGH_RESTORE_CALLS"
assert_equal 'normal restoration clears applied state' 0 "$APPLIED"
expect_success 'normal restoration deletes completed precision records' test ! -e "$BACKUP_PSN_META"
assert_equal 'normal transaction releases its lock' 0 "$LOCK_HELD"

# Missing Clash configuration must not skip the independently owned AGH file.
reset_case
expect_success 'setup for missing-config restoration succeeds' apply_dns_fix manual
rm -f "$CLASH_CONFIG"
expect_failure 'missing Clash config with precision backups is not a successful restore' restore_precision_backup uninstall
assert_equal 'AGH restore still runs when Clash config is missing' 1 "$MOCK_AGH_RESTORE_CALLS"
expect_success 'missing config preserves the PSN restore metadata' test -s "$BACKUP_PSN_META"
expect_success 'missing config preserves the PSN original block' test -s "$BACKUP_PSN"
expect_success 'missing config preserves CN restore records' test -s "$BACKUP_CN_IP"
assert_equal 'missing-config failure releases the lock' 0 "$LOCK_HELD"

# A write to disk is not enough: keep recovery records until reload succeeds.
reset_case
expect_success 'setup for restore-reload failure succeeds' apply_dns_fix manual
MOCK_FAIL_RELOAD_CALL=$((MOCK_RELOAD_CALLS + 1))
expect_failure 'restore surfaces a core reload failure' restore_precision_backup disable
expect_success 'core reload failure preserves PSN metadata' test -s "$BACKUP_PSN_META"
expect_success 'core reload failure preserves the original PSN block' test -s "$BACKUP_PSN"
expect_success 'core reload failure preserves original CN rules' test -s "$BACKUP_CN_IP"
assert_equal 'core reload failure is recorded' restore_reload_failed "$LAST_STATUS"
MOCK_FAIL_RELOAD_CALL=0
expect_success 'restore can finish after the reload problem is removed' restore_precision_backup retry
assert_file_equal 'completed retry restores the exact original config' "$TEST_TMP/config.original" "$CLASH_CONFIG"

# Failing AGH coordination during reapply restores the immediate pre-edit state,
# not the initial pre-module configuration or a partially updated state file.
reset_case
expect_success 'setup for AGH coordination failure succeeds' apply_dns_fix manual
cp -f "$CLASH_CONFIG" "$TEST_TMP/config.before_reapply"
cp -f "$BACKUP_PSN" "$TEST_TMP/psn.before_reapply"
MOCK_TARGET_DNS=tcp://47.105.116.12:8080
MOCK_SYNC_RESULT=ordinary_failure
expect_failure 'ordinary AGH coordination failure is surfaced' apply_dns_fix action
assert_file_equal 'ordinary AGH failure restores the current pre-edit config' "$TEST_TMP/config.before_reapply" "$CLASH_CONFIG"
assert_equal 'ordinary AGH failure restores prior APPLIED state' 1 "$APPLIED"
assert_equal 'ordinary AGH failure restores prior DNS state' tcp://47.105.116.11:8080 "$LAST_APPLIED_DNS"
assert_equal 'ordinary AGH failure restores prior CN optimization state' 1 "$NO_RESOLVE_APPLIED"
assert_equal 'ordinary AGH failure records the rollback' rollback_agh_failed "$LAST_STATUS"
assert_file_equal 'ordinary AGH failure preserves the original restore point' "$TEST_TMP/psn.before_reapply" "$BACKUP_PSN"
expect_success 'restored prior DNS is also persisted' grep -qF 'LAST_APPLIED_DNS=tcp://47.105.116.11:8080' "$STATE_FILE"
expect_success 'successful ordinary rollback cleans the per-operation snapshot' test ! -e "$DATA_DIR/config.yaml.pre_edit.$$"
assert_equal 'ordinary AGH failure releases the lock' 0 "$LOCK_HELD"

# A still-inet AGH may require the newly installed node resolver. Do not undo
# that dependency while AGH rollback is incomplete; retain the original snapshot.
reset_case
MOCK_SYNC_RESULT=rollback_failure
expect_failure 'incomplete AGH rollback is surfaced by the module transaction' apply_dns_fix manual
assert_equal 'incomplete AGH rollback retains independent node DNS' tcp://47.105.116.11:8080 "$(get_active_psn_entries "$CLASH_CONFIG")"
expect_success 'incomplete AGH rollback retains the pre-edit snapshot' test -s "$DATA_DIR/config.yaml.pre_edit.$$"
assert_file_equal 'incomplete AGH snapshot contains the exact prior configuration' "$TEST_TMP/config.original" "$DATA_DIR/config.yaml.pre_edit.$$"
expect_success 'incomplete AGH rollback retains PSN ownership metadata' test -s "$BACKUP_PSN_META"
expect_success 'incomplete AGH rollback retains CN ownership records' test -s "$BACKUP_CN_IP"
assert_equal 'incomplete AGH rollback retains the newly applied node DNS state' 1 "$APPLIED"
assert_equal 'incomplete AGH rollback status remains visible' rollback_failed "$AGH_STATUS"
assert_equal 'incomplete AGH rollback releases the lock for recovery' 0 "$LOCK_HELD"

# A waiting background apply must refresh state and observe disable after lock,
# rather than writing a stale active state over the completed restoration.
reset_case
write_fixture "$TEST_TMP/state.disabled_expected" 'APPLIED=0
LAST_APPLIED_DNS=
NO_RESOLVE_APPLIED=0
LAST_STATUS=restored_disable
AGH_APPLIED=0
AGH_STATUS=inactive'
APPLIED=1
AGH_APPLIED=1
LAST_APPLIED_DNS=tcp://47.105.116.11:8080
AGH_STATUS=active
MOCK_DISABLE_DURING_ACQUIRE=1
expect_success 'background apply safely stops after disable appears while acquiring the lock' apply_dns_fix boot
assert_equal 'disabled background apply never reaches AGH coordination' 0 "$MOCK_SYNC_CALLS"
assert_equal 'disabled background apply never builds a new resolver configuration' 0 "$MOCK_BUILD_CALLS"
assert_file_equal 'disabled background apply leaves restored config unchanged' "$TEST_TMP/config.original" "$CLASH_CONFIG"
assert_file_equal 'disabled background apply does not overwrite refreshed persistent state' "$TEST_TMP/state.disabled_expected" "$STATE_FILE"
assert_equal 'disabled background apply refreshes cached APPLIED state' 0 "$APPLIED"
assert_equal 'disabled background apply refreshes cached AGH status' inactive "$AGH_STATUS"

sync_respects_disable_after_lock() (
  # Restore the real sync wrapper in this subshell; neither mock callback below
  # may access a resolver, kernel rule or phone configuration.
  . "$TEST_REPO/common/agh_fix.sh"
  MOCK_APPLY_CALLBACK_CALLS=0
  apply_agh_fix() { MOCK_APPLY_CALLBACK_CALLS=$((MOCK_APPLY_CALLBACK_CALLS + 1)); return 0; }
  restore_agh_fix() { : > "$TEST_TMP/sync.restore_called"; return 0; }
  AGH_FIX_ENABLED=1
  LOCK_HELD=0
  APPLIED=1
  AGH_STATUS=active
  sync_agh_fix boot || return 1
  [ "$MOCK_APPLY_CALLBACK_CALLS" = 0 ] && [ "$APPLIED" = 0 ] &&
    [ "$AGH_STATUS" = inactive ] &&
    cmp -s "$TEST_TMP/state.disabled_expected" "$STATE_FILE" || return 1
  AGH_FIX_ENABLED=0
  sync_agh_fix disabled_option || return 1
  [ -f "$TEST_TMP/sync.restore_called" ]
)
expect_success 'real AGH sync skips disabled apply without saving stale state but still allows restore' sync_respects_disable_after_lock

# The disable watcher may time out while a slow apply owns the lock. The apply
# transaction itself must perform the full module restoration before releasing it.
late_disable_restores_full_module() (
  reset_case
  . "$TEST_REPO/common/agh_fix.sh"
  MOCK_LATE_APPLY_CALLS=0
  MOCK_LATE_RESTORE_CALLS=0
  apply_agh_fix() {
    [ "$LOCK_HELD" = 1 ] || return 1
    MOCK_LATE_APPLY_CALLS=$((MOCK_LATE_APPLY_CALLS + 1))
    AGH_APPLIED=1
    AGH_STATUS=active
    save_state
    : > "$LIVE_MOD_DIR/disable"
    return 0
  }
  restore_agh_fix() {
    [ "$LOCK_HELD" = 1 ] || return 1
    MOCK_LATE_RESTORE_CALLS=$((MOCK_LATE_RESTORE_CALLS + 1))
    AGH_APPLIED=0
    AGH_STATUS=inactive
    save_state
    return 0
  }
  AGH_FIX_ENABLED=1
  apply_dns_fix boot || return 1
  [ "$MOCK_LATE_APPLY_CALLS" = 1 ] && [ "$MOCK_LATE_RESTORE_CALLS" = 1 ] &&
    [ "$APPLIED" = 0 ] && [ "$AGH_APPLIED" = 0 ] && [ "$LOCK_HELD" = 0 ] &&
    [ ! -e "$BACKUP_PSN_META" ] &&
    cmp -s "$TEST_TMP/config.original" "$CLASH_CONFIG"
)
expect_success 'late disable restores the full original configuration while locked and leaves the module inactive' late_disable_restores_full_module

# Failure to locate the original DNS block cannot be recovered by copying the
# current config and falsely reporting a successful restore.
reset_case
expect_success 'setup for DNS-block splice failure succeeds' apply_dns_fix manual
$AWK '
  /^dns:/ { in_dns=1; next }
  in_dns && /^[^[:space:]#]/ { in_dns=0 }
  !in_dns { print }
' "$CLASH_CONFIG" > "$TEST_TMP/config.without_dns"
cp -f "$TEST_TMP/config.without_dns" "$CLASH_CONFIG"
expect_failure 'restore surfaces a missing original DNS insertion point even when validation would pass' restore_precision_backup disable
assert_equal 'DNS splice failure has an explicit persisted status' restore_splice_failed "$LAST_STATUS"
assert_file_equal 'DNS splice failure does not rewrite current user config' "$TEST_TMP/config.without_dns" "$CLASH_CONFIG"
expect_success 'DNS splice failure retains PSN metadata' test -s "$BACKUP_PSN_META"
expect_success 'DNS splice failure retains the original PSN block' test -s "$BACKUP_PSN"
expect_success 'DNS splice failure retains CN restoration data' test -s "$BACKUP_CN_IP"

# Run the actual installer, not a copied cleanup branch. APPLIED=0 does not
# imply that a failed first-install write was rolled back successfully.
installer_failure_preserves_recovery() {
  local module="$TEST_TMP/installer-module" data="$TEST_TMP/installer-data" file=""
  mkdir -p "$module/common" "$data"
  write_fixture "$data/config.yaml" 'dns:
  enable: true'
  write_fixture "$module/common/dns_lib.sh" 'init_env() {
  DATA_DIR=$INSTALLER_TEST_ROOT
  BACKUP_DIR=$INSTALLER_TEST_ROOT
  CLASH_CONFIG=$INSTALLER_TEST_ROOT/config.yaml
  SETTINGS_FILE=$INSTALLER_TEST_ROOT/settings.conf
  STATE_FILE=$INSTALLER_TEST_ROOT/state.conf
  BACKUP_FULL=$INSTALLER_TEST_ROOT/full.orig
  BACKUP_PSN=$INSTALLER_TEST_ROOT/psn.orig
  BACKUP_PSN_META=$INSTALLER_TEST_ROOT/psn.meta
  BACKUP_CN_IP=$INSTALLER_TEST_ROOT/cn.orig
  LOG_FILE=$INSTALLER_TEST_ROOT/module.log
  LIVE_MOD_DIR=$INSTALLER_TEST_ROOT/absent-live-module
  APPLIED=0
}
# Force immediate default volume-key choices without querying real hardware.
getevent() { return 0; }
apply_dns_fix() {
  printf "full recovery snapshot\n" > "$BACKUP_FULL"
  printf "original PSN block\n" > "$BACKUP_PSN"
  printf "ORIGINAL_HAD_BLOCK=1\n" > "$BACKUP_PSN_META"
  printf "original CN rule\n" > "$BACKUP_CN_IP"
  APPLIED=0
  LAST_STATUS=write_rollback_failed
  printf "APPLIED=0\nLAST_STATUS=write_rollback_failed\n" > "$STATE_FILE"
  printf "apply was called\n" > "$DATA_DIR/apply.called"
  return 1
}'
  if INSTALLER_TEST_ROOT="$data" MODPATH="$module" sh "$TEST_REPO/customize.sh" > "$data/installer-output.log" 2>&1; then
    printf 'Fixture installer unexpectedly succeeded\n' >&2
    return 1
  fi
  [ -s "$data/apply.called" ] || return 1
  for file in full.orig psn.orig psn.meta cn.orig state.conf; do
    if [ ! -s "$data/$file" ]; then
      printf 'Installer discarded recovery file: %s\n' "$file" >&2
      return 1
    fi
  done
  grep -qxF 'APPLIED=0' "$data/state.conf" &&
    grep -qxF 'LAST_STATUS=write_rollback_failed' "$data/state.conf"
}
expect_success 'failed first-time installer preserves recovery files even with APPLIED=0' installer_failure_preserves_recovery

printf '1..%s\n' "$TEST_COUNT"
