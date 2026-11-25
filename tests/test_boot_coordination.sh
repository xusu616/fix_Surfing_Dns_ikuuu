#!/bin/sh
# Source a copy of the real service.sh and wait for its background worker.
# The fixture library replaces every Android/runtime operation; init_env here
# only supplies private fixture paths and never loads a real module environment.
set -eu

TEST_REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/boot-coordination-tests.XXXXXX")
TEST_COUNT=0

cleanup() {
  case "$TEST_TMP" in
    "${TMPDIR:-/tmp}"/boot-coordination-tests.??????) ;;
    *) printf 'Refusing to clean an unexpected fixture path: %s\n' "$TEST_TMP" >&2; return 1 ;;
  esac
  rm -f -- "$TEST_TMP/common/dns_lib.sh"
  rmdir -- "$TEST_TMP/common"
  for fixture in "$TEST_TMP"/* "$TEST_TMP"/.[!.]*; do
    [ -f "$fixture" ] || continue
    rm -f -- "$fixture"
  done
  rmdir -- "$TEST_TMP"
}
trap cleanup 0

ok() { TEST_COUNT=$((TEST_COUNT + 1)); printf 'ok %s - %s\n' "$TEST_COUNT" "$1"; }
fail() { TEST_COUNT=$((TEST_COUNT + 1)); printf 'not ok %s - %s\n' "$TEST_COUNT" "$1" >&2; exit 1; }
assert_equal() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (expected: $2; actual: $3)"; fi; }
assert_contains() { if grep -qF "$2" "$3"; then ok "$1"; else fail "$1"; fi; }
event_count() { wc -l < "$1" | tr -d ' '; }

mkdir "$TEST_TMP/common"
cp -f "$TEST_REPO/service.sh" "$TEST_TMP/service.sh"
printf '%s\n' 'init_env() {
  DATA_DIR=$BOOT_FIXTURE_ROOT
  LOG_FILE=$BOOT_FIXTURE_ROOT/module.log
  CLASH_CONFIG=$BOOT_FIXTURE_ROOT/config.yaml
  BOX_BIN_NAME=clash
  AWK=awk
  SED=sed
  AGH_FIX_ENABLED=1
  AGH_STATUS=inactive
  DNS_WRITE_MODE=ip
  USED_DOMAIN_FALLBACK=0
  ADD_CN_IP_NORESOLVE=0
  LAST_APPLIED_DNS=tcp://47.105.116.11:8080
  case "$BOOT_SCENARIO" in
    first_failure|first_rollback_failure|dns_success) APPLIED=0; AUTO_BOOT_SYNC=0 ;;
    drift_failure|cached_ip_skip) APPLIED=1; AUTO_BOOT_SYNC=1 ;;
    agh_only) APPLIED=1; AUTO_BOOT_SYNC=0 ;;
    *) return 1 ;;
  esac
}
log_msg() { printf "%s\n" "$1" >> "$LOG_FILE"; }
start_module_inotifyd() { log_msg "fixture watcher started"; }
update_module_desc() { log_msg "fixture description updated"; }
getprop() { printf "1\n"; }
pidof() { printf "24680\n"; }
iptables() { return 0; }
has_online_network() { return 0; }
agh_has_changes() { return 1; }
get_active_psn_entries() { printf "tcp://47.105.116.11:8080\n"; }
is_usable_public_ipv4() { [ "$1" = 47.105.116.11 ]; }
build_target_dns_entries() {
  case "$BOOT_SCENARIO" in
    drift_failure) TARGET_DNS_LIST=tcp://47.105.116.12:8080 ;;
    cached_ip_skip) TARGET_DNS_LIST=tcp://resolver.example:8080; USED_DOMAIN_FALLBACK=1 ;;
    *) TARGET_DNS_LIST=tcp://47.105.116.11:8080 ;;
  esac
  return 0
}
apply_dns_fix() {
  printf "%s\n" "$1" >> "$DATA_DIR/dns.events"
  case "$BOOT_SCENARIO" in
    dns_success)
      APPLIED=1
      AGH_STATUS=active
      printf "AGH coordinated inside DNS transaction\n" >> "$DATA_DIR/internal-agh.events"
      return 0 ;;
    first_rollback_failure|drift_failure)
      AGH_STATUS=rollback_failed
      printf "pending rollback evidence\n" > "$DATA_DIR/recovery.snapshot"
      return 1 ;;
    *) AGH_STATUS=validation_failed; return 1 ;;
  esac
}
sync_agh_fix() {
  printf "%s\n" "$1" >> "$DATA_DIR/standalone-agh.events"
  AGH_STATUS=active
  return 0
}' > "$TEST_TMP/common/dns_lib.sh"

run_scenario() {
  local scenario="$1"
  : > "$TEST_TMP/dns.events"
  : > "$TEST_TMP/standalone-agh.events"
  : > "$TEST_TMP/internal-agh.events"
  : > "$TEST_TMP/module.log"
  rm -f "$TEST_TMP/recovery.snapshot"
  printf 'dns:\n  proxy-server-nameserver:\n    - tcp://47.105.116.11:8080\n' > "$TEST_TMP/config.yaml"
  # Set both $0 and $1 to the fixture service so its MODDIR resolution stays
  # inside TEST_TMP. wait makes counter assertions observe the completed worker.
  if ! BOOT_FIXTURE_ROOT="$TEST_TMP" BOOT_SCENARIO="$scenario" \
    sh -c '. "$1"; wait' "$TEST_TMP/service.sh" "$TEST_TMP/service.sh" \
    > "$TEST_TMP/service-output.log" 2>&1; then
    fail "fixture service completed: $scenario"
  fi
}

run_scenario first_failure
assert_equal 'APPLIED=0 attempts DNS once' 1 "$(event_count "$TEST_TMP/dns.events")"
assert_equal 'ordinary DNS failure does not immediately retry AGH independently' 0 "$(event_count "$TEST_TMP/standalone-agh.events")"
assert_contains 'first DNS attempt has the boot_reenable reason' boot_reenable "$TEST_TMP/dns.events"
assert_contains 'first DNS failure records preserved recovery state' 'Boot application failed; recovery records preserved' "$TEST_TMP/module.log"

run_scenario first_rollback_failure
assert_equal 'initial rollback failure attempts DNS once' 1 "$(event_count "$TEST_TMP/dns.events")"
assert_equal 'initial AGH rollback failure prevents independent continuation' 0 "$(event_count "$TEST_TMP/standalone-agh.events")"
assert_contains 'initial rollback failure keeps the recovery snapshot' 'pending rollback evidence' "$TEST_TMP/recovery.snapshot"
assert_contains 'initial rollback failure is logged' 'Boot application failed; recovery records preserved' "$TEST_TMP/module.log"

run_scenario drift_failure
assert_equal 'subscription drift attempts DNS synchronization once' 1 "$(event_count "$TEST_TMP/dns.events")"
assert_equal 'failed drift synchronization prevents independent AGH continuation' 0 "$(event_count "$TEST_TMP/standalone-agh.events")"
assert_contains 'drift transaction has the boot_sync reason' boot_sync "$TEST_TMP/dns.events"
assert_contains 'drift failure is recorded without a second repair' 'Boot DNS sync failed; recovery records preserved' "$TEST_TMP/module.log"

run_scenario agh_only
assert_equal 'ordinary boot with AUTO_BOOT_SYNC=0 does not attempt DNS' 0 "$(event_count "$TEST_TMP/dns.events")"
assert_equal 'ordinary boot independently coordinates AGH once' 1 "$(event_count "$TEST_TMP/standalone-agh.events")"
assert_contains 'independent AGH coordination has the boot reason' boot "$TEST_TMP/standalone-agh.events"

run_scenario dns_success
assert_equal 'successful initial DNS transaction is attempted once' 1 "$(event_count "$TEST_TMP/dns.events")"
assert_equal 'successful DNS transaction does not duplicate its AGH coordination' 0 "$(event_count "$TEST_TMP/standalone-agh.events")"
assert_equal 'successful DNS transaction coordinates AGH internally once' 1 "$(event_count "$TEST_TMP/internal-agh.events")"

run_scenario cached_ip_skip
assert_equal 'cached valid node IP safely skips a domain-fallback DNS overwrite' 0 "$(event_count "$TEST_TMP/dns.events")"
assert_equal 'safe DNS skip still permits independent AGH coordination once' 1 "$(event_count "$TEST_TMP/standalone-agh.events")"
assert_contains 'safe DNS skip uses the independent boot coordination reason' boot "$TEST_TMP/standalone-agh.events"

printf '1..%s\n' "$TEST_COUNT"
