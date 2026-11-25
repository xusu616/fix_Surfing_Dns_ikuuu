#!/bin/sh
# Lifecycle regression tests. No Android process, root service or real network
# is touched: only private fixture files and the I/O mocks below are used.
set -eu

TEST_REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/agh-lifecycle-tests.XXXXXX")
TEST_COUNT=0

cleanup() {
  case "$TEST_TMP" in
    "${TMPDIR:-/tmp}"/agh-lifecycle-tests.??????) ;;
    *) printf 'Refusing to clean an unexpected fixture path: %s\n' "$TEST_TMP" >&2; return 1 ;;
  esac
  for fixture in "$TEST_TMP"/* "$TEST_TMP"/.[!.]*; do
    [ -f "$fixture" ] || continue
    rm -f -- "$fixture"
  done
  rmdir -- "$TEST_TMP"
}
trap cleanup 0

ok() {
  TEST_COUNT=$((TEST_COUNT + 1))
  printf 'ok %s - %s\n' "$TEST_COUNT" "$1"
}

fail() {
  TEST_COUNT=$((TEST_COUNT + 1))
  printf 'not ok %s - %s\n' "$TEST_COUNT" "$1" >&2
  exit 1
}

expect_success() {
  description=$1
  shift
  if "$@"; then ok "$description"; else fail "$description"; fi
}

expect_failure() {
  description=$1
  shift
  if "$@"; then fail "$description"; else ok "$description"; fi
}

assert_equal() {
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (expected: $2; actual: $3)"; fi
}

assert_file_equal() {
  if cmp -s "$2" "$3"; then ok "$1"; else fail "$1"; fi
}

write_fixture() { printf '%s\n' "$2" > "$1"; }

AWK=${AWK:-awk}
SED=${SED:-sed}
MOD_ID=fix_Surfing_Dns_ikuuu
DATA_DIR=$TEST_TMP
BACKUP_DIR=$TEST_TMP
AGH_SETTINGS=$TEST_TMP/settings.conf
AGH_YAML=$TEST_TMP/AdGuardHome.yaml
AGH_TOOL=$TEST_TMP/agh-tool.sh
AGH_GROUP_BACKUP=$TEST_TMP/agh_group.orig
AGH_RULES_ADDED=$TEST_TMP/agh_rules.added
CLASH_CONFIG=$TEST_TMP/config.yaml
STATE_FILE=$TEST_TMP/state.conf
LOG_FILE=$TEST_TMP/module.log
MOCK_EVENTS=$TEST_TMP/events.log
MODPATH=$TEST_REPO
LIVE_MOD_DIR=$TEST_REPO

. "$TEST_REPO/common/agh_fix.sh"

log_msg() { printf '%s\n' "$1" >> "$LOG_FILE"; }
print_out() { log_msg "$1"; }
save_state() {
  printf 'AGH_APPLIED=%s\nAGH_STATUS=%s\n' "$AGH_APPLIED" "$AGH_STATUS" > "$STATE_FILE"
}
get_active_psn_entries() { printf '%s\n' "$MOCK_NODE_DNS"; }
is_usable_public_ipv4() { [ "$1" = 47.105.116.11 ]; }

agh_runtime_ready() {
  if [ "$MOCK_RUNTIME_READY" = 1 ]; then return 0; fi
  AGH_STATUS=waiting_surfing
  return 1
}

agh_pid() {
  [ "$MOCK_RUNNING" = 1 ] || return 1
  [ "$MOCK_PID_COUNT" = 1 ] || return 2
  printf '12345\n'
}

agh_pid_gid() { printf '%s\n' "$MOCK_GID"; }
agh_pid_uid() { printf '%s\n' "$MOCK_UID"; }

agh_restart_running() {
  local running="$1" expected="$2"
  printf 'restart:%s:%s\n' "$running" "$expected" >> "$MOCK_EVENTS"
  MOCK_RESTART_CALLS=$((MOCK_RESTART_CALLS + 1))
  [ "$running" = 1 ] || return 0
  # Simulate a partially completed start: the new identity may be live even
  # when readiness validation fails, making rollback ordering significant.
  if [ "$expected" = 3003 ] && [ "$MOCK_FAIL_NEW_RESTART" = 1 ] && [ "$MOCK_NEW_RESTART_FAILED" = 0 ]; then
    MOCK_GID=3003
    MOCK_NEW_RESTART_FAILED=1
    return 1
  fi
  if [ "$expected" = 3005 ] && [ "$MOCK_FAIL_OLD_RESTART" = 1 ]; then return 1; fi
  MOCK_GID=$expected
  return 0
}

validate_config_file() {
  [ "$MOCK_CONFIG_VALID" = 1 ] && [ -s "$1" ]
}

copy_file_preserve_meta() {
  local source="$1" destination="$2"
  if [ "$destination" = "$CLASH_CONFIG" ]; then
    if agh_rules_ready "$source"; then
      printf 'copy_config:managed\n' >> "$MOCK_EVENTS"
    else
      printf 'copy_config:original\n' >> "$MOCK_EVENTS"
    fi
  elif [ "$destination" = "$AGH_SETTINGS" ]; then
    printf 'copy_group:%s\n' "$(agh_setting_value "$source" adg_group)" >> "$MOCK_EVENTS"
  fi
  cp -f "$source" "$destination"
}

reload_surfing_if_running() {
  MOCK_RELOAD_CALLS=$((MOCK_RELOAD_CALLS + 1))
  printf 'reload:%s\n' "$MOCK_RELOAD_CALLS" >> "$MOCK_EVENTS"
  [ "$MOCK_RELOAD_CALLS" -ne "$MOCK_FAIL_RELOAD_CALL" ]
}

event_index() {
  $AWK -v event="$1" '$0 == event { print NR; exit }' "$MOCK_EVENTS"
}

reset_case() {
  write_fixture "$AGH_SETTINGS" 'enable_iptables=false
redir_port=51248
adg_user=root
adg_group="net_admin" # original group formatting
startup_timeout=120'
  write_fixture "$AGH_YAML" 'dns:
  upstream_dns:
    - https://1.12.12.12/dns-query
    - https://120.53.53.53/dns-query
  upstream_dns_file: ""
  fallback_dns:
    - https://101.226.4.6/dns-query'
  write_fixture "$CLASH_CONFIG" 'mode: Rule
dns:
  proxy-server-nameserver:
    - tcp://47.105.116.11:8080
  nameserver:
    - 127.0.0.1:51248
rules:
  - DST-PORT,53,DNS_Hijack
  - RULE-SET,CN_IP,DIRECT,no-resolve
  - MATCH,PROXY'
  write_fixture "$AGH_TOOL" '#!/bin/sh
# busybox setuidgid "$adg_user:$adg_group" "$BIN_DIR/AdGuardHome"
exit 0'
  chmod 700 "$AGH_TOOL"
  cp -f "$CLASH_CONFIG" "$TEST_TMP/config.original"
  cp -f "$AGH_SETTINGS" "$TEST_TMP/settings.original"
  rm -f "$AGH_GROUP_BACKUP" "$AGH_RULES_ADDED" "$STATE_FILE"
  : > "$MOCK_EVENTS"
  : > "$LOG_FILE"
  AGH_APPLIED=0
  AGH_STATUS=inactive
  MOCK_RUNNING=1
  MOCK_PID_COUNT=1
  MOCK_UID=0
  MOCK_GID=3005
  MOCK_NODE_DNS=tcp://47.105.116.11:8080
  MOCK_RUNTIME_READY=1
  MOCK_CONFIG_VALID=1
  MOCK_RELOAD_CALLS=0
  MOCK_FAIL_RELOAD_CALL=0
  MOCK_RESTART_CALLS=0
  MOCK_FAIL_NEW_RESTART=0
  MOCK_NEW_RESTART_FAILED=0
  MOCK_FAIL_OLD_RESTART=0
}

# First application owns only the actual group change and added priority rules.
reset_case
expect_success 'first application succeeds' apply_agh_fix manual
assert_equal 'first application changes the launch group' inet "$(agh_setting_value "$AGH_SETTINGS" adg_group)"
assert_equal 'first application restarts with the expected identity' 3003 "$MOCK_GID"
expect_success 'first application installs priority routing rules' agh_rules_ready "$CLASH_CONFIG"
expect_success 'original group formatting is recorded' grep -qF 'adg_group="net_admin" # original group formatting' "$AGH_GROUP_BACKUP"
assert_equal 'the module records exactly its two added rules' 2 "$(wc -l < "$AGH_RULES_ADDED" | tr -d ' ')"
assert_equal 'successful application is persisted as active' active "$AGH_STATUS"

# Restore must retain user changes made after installation outside owned fields.
$AWK '{ sub(/^redir_port=51248$/, "redir_port=54545"); print } END { print "user_added_setting=true" }' "$AGH_SETTINGS" > "$TEST_TMP/settings.user_changes"
cp -f "$TEST_TMP/settings.user_changes" "$AGH_SETTINGS"
$AWK '{ sub(/^redir_port=51248$/, "redir_port=54545"); print } END { print "user_added_setting=true" }' "$TEST_TMP/settings.original" > "$TEST_TMP/settings.restore_expected"
$AWK '/^  - MATCH,/ { print "  - DOMAIN,user.example,DIRECT" } { print }' "$CLASH_CONFIG" > "$TEST_TMP/config.user_changes"
cp -f "$TEST_TMP/config.user_changes" "$CLASH_CONFIG"
$AWK '/^  - MATCH,/ { print "  - DOMAIN,user.example,DIRECT" } { print }' "$TEST_TMP/config.original" > "$TEST_TMP/config.restore_expected"
expect_success 'restore first application succeeds' restore_agh_fix disable
assert_file_equal 'restore preserves unrelated AGH user edits' "$TEST_TMP/settings.restore_expected" "$AGH_SETTINGS"
assert_file_equal 'restore preserves unrelated routing user edits' "$TEST_TMP/config.restore_expected" "$CLASH_CONFIG"
assert_equal 'restoration returns the running AGH identity' 3005 "$MOCK_GID"
expect_success 'successful restoration removes the owned group backup' test ! -e "$AGH_GROUP_BACKUP"
expect_success 'successful restoration removes the owned rule record' test ! -e "$AGH_RULES_ADDED"
assert_equal 'successful restoration is persisted as inactive' inactive "$AGH_STATUS"

# Previously manual fixes must not acquire ownership, even when later disabled.
reset_case
agh_write_group "$AGH_SETTINGS" inet "$TEST_TMP/settings.manual"
cp -f "$TEST_TMP/settings.manual" "$AGH_SETTINGS"
write_fixture "$CLASH_CONFIG" 'mode: Rule
rules:
  - IP-CIDR,1.12.12.12/32,DNS连接,no-resolve # user rule A
  - IP-CIDR,120.53.53.53/32,DNS连接,no-resolve # user rule B
  - MATCH,PROXY'
cp -f "$AGH_SETTINGS" "$TEST_TMP/settings.manual_original"
cp -f "$CLASH_CONFIG" "$TEST_TMP/config.manual_original"
MOCK_GID=3003
expect_success 'already manually fixed setup is accepted' apply_agh_fix manual
expect_success 'manual group is not claimed' test ! -s "$AGH_GROUP_BACKUP"
expect_success 'manual routing rules are not claimed' test ! -s "$AGH_RULES_ADDED"
assert_file_equal 'manual settings are not rewritten' "$TEST_TMP/settings.manual_original" "$AGH_SETTINGS"
assert_file_equal 'manual routing is not rewritten' "$TEST_TMP/config.manual_original" "$CLASH_CONFIG"
expect_success 'disable with no owned changes succeeds' restore_agh_fix disable
assert_file_equal 'disable leaves the manually fixed settings intact' "$TEST_TMP/settings.manual_original" "$AGH_SETTINGS"
assert_file_equal 'disable leaves the manually fixed rules intact' "$TEST_TMP/config.manual_original" "$CLASH_CONFIG"
assert_equal 'manual setup requires no reload' 0 "$MOCK_RELOAD_CALLS"
assert_equal 'manual setup requires no restart' 0 "$MOCK_RESTART_CALLS"

# Reapplication and drift repair must not overwrite the first restore point.
reset_case
expect_success 'setup for replay backup checks succeeds' apply_agh_fix manual
cp -f "$AGH_GROUP_BACKUP" "$TEST_TMP/group.first_backup"
expect_success 'reapply an already active setup succeeds' apply_agh_fix action
assert_file_equal 'reapplication preserves the first group backup' "$TEST_TMP/group.first_backup" "$AGH_GROUP_BACKUP"
write_fixture "$AGH_SETTINGS" 'enable_iptables=false
redir_port=51248
adg_user=root
adg_group=net_admin # drift after the original backup
startup_timeout=180'
MOCK_GID=3005
expect_success 'repair group drift succeeds' apply_agh_fix boot
assert_file_equal 'drift repair still preserves the first group backup' "$TEST_TMP/group.first_backup" "$AGH_GROUP_BACKUP"
assert_equal 'drift repair returns to inet' 3003 "$MOCK_GID"
expect_success 'restoration after replay succeeds' restore_agh_fix disable

# An I/O failure must roll back both the persisted data and effective identity.
reset_case
MOCK_FAIL_RELOAD_CALL=1
expect_failure 'first Surfing reload failure is surfaced' apply_agh_fix manual
assert_file_equal 'reload failure restores the original routing file' "$TEST_TMP/config.original" "$CLASH_CONFIG"
assert_file_equal 'reload failure leaves original AGH settings' "$TEST_TMP/settings.original" "$AGH_SETTINGS"
assert_equal 'reload failure leaves the original running identity' 3005 "$MOCK_GID"
expect_success 'reload rollback leaves no owned group backup' test ! -s "$AGH_GROUP_BACKUP"
expect_success 'reload rollback leaves no owned rule record' test ! -s "$AGH_RULES_ADDED"
assert_equal 'reload failure records successful rollback' apply_failed_rolled_back "$AGH_STATUS"

reset_case
MOCK_FAIL_NEW_RESTART=1
expect_failure 'new AGH readiness failure is surfaced' apply_agh_fix manual
assert_file_equal 'AGH failure restores original routing' "$TEST_TMP/config.original" "$CLASH_CONFIG"
assert_file_equal 'AGH failure restores original settings' "$TEST_TMP/settings.original" "$AGH_SETTINGS"
assert_equal 'AGH failure restores original running identity' 3005 "$MOCK_GID"
expect_success 'AGH rollback leaves no owned group backup' test ! -s "$AGH_GROUP_BACKUP"
expect_success 'AGH rollback leaves no owned rule record' test ! -s "$AGH_RULES_ADDED"
assert_equal 'AGH restart failure records successful rollback' apply_failed_rolled_back "$AGH_STATUS"
RESTORE_IDENTITY_INDEX=$(event_index restart:1:3005)
RESTORE_CONFIG_INDEX=$(event_index copy_config:original)
expect_success 'rollback restores identity before removing proxy rules' test "$RESTORE_IDENTITY_INDEX" -lt "$RESTORE_CONFIG_INDEX"

# A later user-selected group is a conflict, not permission to overwrite it.
reset_case
expect_success 'setup for group conflict succeeds' apply_agh_fix manual
$AWK '/^adg_group=/ { print "adg_group=shell"; next } { print }' "$AGH_SETTINGS" > "$TEST_TMP/settings.conflict"
cp -f "$TEST_TMP/settings.conflict" "$AGH_SETTINGS"
cp -f "$CLASH_CONFIG" "$TEST_TMP/config.conflict"
MOCK_GID=2000
expect_failure 'restore surfaces a later group conflict' restore_agh_fix disable
assert_file_equal 'conflict preserves the later user-selected group' "$TEST_TMP/settings.conflict" "$AGH_SETTINGS"
assert_file_equal 'conflict does not remove still-required proxy rules' "$TEST_TMP/config.conflict" "$CLASH_CONFIG"
expect_success 'conflict preserves group recovery data' test -s "$AGH_GROUP_BACKUP"
expect_success 'conflict preserves rule recovery data' test -s "$AGH_RULES_ADDED"
assert_equal 'group conflict is persisted' restore_group_conflict "$AGH_STATUS"

# Missing Clash config must not make uninstall discard the independent backup.
reset_case
expect_success 'setup for a missing Clash configuration succeeds' apply_agh_fix manual
rm -f "$CLASH_CONFIG"
expect_failure 'missing Clash configuration prevents a false restore success' restore_agh_fix uninstall
assert_file_equal 'group is restored independently before the missing rule file is reported' "$TEST_TMP/settings.original" "$AGH_SETTINGS"
assert_equal 'identity is restored despite missing Clash configuration' 3005 "$MOCK_GID"
expect_success 'missing config preserves pending rule recovery data' test -s "$AGH_RULES_ADDED"
expect_success 'missing config also retains the group restore point until completion' test -s "$AGH_GROUP_BACKUP"
assert_equal 'missing config is persisted as a rule restoration failure' restore_rules_failed "$AGH_STATUS"
cp -f "$TEST_TMP/config.original" "$CLASH_CONFIG"
expect_success 'restoration can finish once the missing config is returned' restore_agh_fix retry
expect_success 'completed retry finally removes recovery data' test ! -e "$AGH_RULES_ADDED"

# A failed rollback must keep evidence instead of declaring the module inactive.
reset_case
MOCK_FAIL_NEW_RESTART=1
MOCK_FAIL_OLD_RESTART=1
expect_failure 'failed old-identity restart surfaces incomplete rollback' apply_agh_fix manual
assert_equal 'incomplete rollback is persisted' rollback_failed "$AGH_STATUS"
expect_success 'incomplete rollback retains the original group backup' test -s "$AGH_GROUP_BACKUP"
expect_success 'incomplete rollback retains owned rule recovery data' test -s "$AGH_RULES_ADDED"
expect_success 'incomplete rollback retains pre-edit settings snapshot' test -s "$DATA_DIR/agh_settings.pre.$$"
expect_success 'incomplete rollback retains pre-edit routing snapshot' test -s "$DATA_DIR/agh_config.pre.$$"
expect_success 'proxy rules remain while the effective identity has not recovered' agh_rules_ready "$CLASH_CONFIG"
MOCK_FAIL_OLD_RESTART=0
expect_success 'explicit recovery can complete an incomplete rollback' restore_agh_fix recovery
assert_equal 'explicit recovery restores the original identity' 3005 "$MOCK_GID"

# An intentionally stopped resolver must stay stopped through apply and restore.
reset_case
MOCK_RUNNING=0
expect_success 'apply can prepare settings for an intentionally stopped AGH' apply_agh_fix manual
assert_equal 'application does not start an intentionally stopped AGH' 0 "$MOCK_RUNNING"
expect_success 'restore an intentionally stopped AGH succeeds' restore_agh_fix disable
assert_equal 'restoration does not start an intentionally stopped AGH' 0 "$MOCK_RUNNING"
assert_file_equal 'stopped resolver restoration keeps the original settings' "$TEST_TMP/settings.original" "$AGH_SETTINGS"

# Real process identity, not only the settings file, controls compatibility.
reset_case
MOCK_UID=2000
expect_failure 'application refuses a non-root live resolver' apply_agh_fix manual
assert_equal 'non-root identity failure is persisted' unexpected_agh_identity "$AGH_STATUS"
assert_file_equal 'non-root resolver settings stay untouched' "$TEST_TMP/settings.original" "$AGH_SETTINGS"
assert_file_equal 'non-root resolver routing stays untouched' "$TEST_TMP/config.original" "$CLASH_CONFIG"
expect_success 'non-root rejection does not create recovery ownership' test ! -s "$AGH_GROUP_BACKUP"

reset_case
MOCK_PID_COUNT=2
expect_failure 'application refuses multiple live AGH processes' apply_agh_fix manual
assert_equal 'multiple-process failure is persisted' multiple_agh_processes "$AGH_STATUS"
assert_file_equal 'multiple-process rejection preserves settings' "$TEST_TMP/settings.original" "$AGH_SETTINGS"
assert_file_equal 'multiple-process rejection preserves routing' "$TEST_TMP/config.original" "$CLASH_CONFIG"

reset_case
MOCK_NODE_DNS=tcp://127.0.0.1:51248
expect_success 'unsupported localhost node DNS is safely skipped' apply_agh_fix manual
assert_equal 'looping node DNS configuration is marked unsupported' unsupported_configuration "$AGH_STATUS"
assert_file_equal 'localhost node DNS does not trigger a group change' "$TEST_TMP/settings.original" "$AGH_SETTINGS"
assert_file_equal 'localhost node DNS does not trigger routing changes' "$TEST_TMP/config.original" "$CLASH_CONFIG"
expect_success 'localhost node DNS rejection creates no rule ownership' test ! -s "$AGH_RULES_ADDED"

# An edited module marker is not authority to replace or delete user changes.
reset_case
expect_success 'setup for a module-marked rule edit succeeds' apply_agh_fix manual
$AWK '/# fix_Surfing_Dns_ikuuu: agh-doh/ && !changed { sub(/DNS连接/, "UserChangedProxy"); changed=1 } { print }' "$CLASH_CONFIG" > "$TEST_TMP/config.marker_conflict"
cp -f "$TEST_TMP/config.marker_conflict" "$CLASH_CONFIG"
cp -f "$AGH_RULES_ADDED" "$TEST_TMP/rules.marker_record"
cp -f "$AGH_GROUP_BACKUP" "$TEST_TMP/group.marker_backup"
expect_failure 'application refuses an edited module-marked rule' apply_agh_fix action
assert_equal 'edited rule application conflict is persisted' conflicting_rules "$AGH_STATUS"
assert_file_equal 'application conflict preserves the edited rule' "$TEST_TMP/config.marker_conflict" "$CLASH_CONFIG"
assert_file_equal 'application conflict preserves original ownership record' "$TEST_TMP/rules.marker_record" "$AGH_RULES_ADDED"
expect_failure 'restoration refuses an edited module-marked rule' restore_agh_fix disable
assert_equal 'edited rule restoration conflict is persisted' restore_rules_conflict "$AGH_STATUS"
assert_equal 'rule conflict does not silently change the resolver identity' 3003 "$MOCK_GID"
assert_file_equal 'restoration conflict retains the group restore point' "$TEST_TMP/group.marker_backup" "$AGH_GROUP_BACKUP"
assert_file_equal 'restoration conflict retains the rule ownership record' "$TEST_TMP/rules.marker_record" "$AGH_RULES_ADDED"

# Corrupt recovery records must not be treated as absent ownership or replaced.
reset_case
: > "$AGH_GROUP_BACKUP"
expect_failure 'application rejects an empty existing group backup' apply_agh_fix manual
expect_failure 'restoration rejects an empty existing group backup' restore_agh_fix disable
expect_success 'empty corrupt group backup remains available for inspection' test -e "$AGH_GROUP_BACKUP"

reset_case
write_fixture "$AGH_RULES_ADDED" '  - DOMAIN,user.example,DIRECT'
cp -f "$AGH_RULES_ADDED" "$TEST_TMP/rules.corrupt_original"
expect_failure 'application rejects a non-module rule ownership record' apply_agh_fix manual
expect_failure 'restoration rejects a non-module rule ownership record' restore_agh_fix disable
assert_file_equal 'invalid rule ownership record is preserved instead of overwritten or deleted' "$TEST_TMP/rules.corrupt_original" "$AGH_RULES_ADDED"

printf '1..%s\n' "$TEST_COUNT"
