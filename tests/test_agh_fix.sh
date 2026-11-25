#!/bin/sh
# Run with a POSIX shell or BusyBox ash. All fixtures stay in a private temp dir.
set -eu

TEST_REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/agh-fix-tests.XXXXXX")
TEST_COUNT=0

cleanup() {
  # This directory was created by this test; never recursively remove a parent.
  case "$TEST_TMP" in
    "${TMPDIR:-/tmp}"/agh-fix-tests.??????) ;;
    *) printf 'Refusing to clean an unexpected fixture path: %s\n' "$TEST_TMP" >&2; return 1 ;;
  esac
  for fixture in "$TEST_TMP"/* "$TEST_TMP"/.[!.]*; do
    [ -f "$fixture" ] || continue
    rm -f -- "$fixture"
  done
  rmdir -- "$TEST_TMP"
}
trap cleanup 0

fail() {
  TEST_COUNT=$((TEST_COUNT + 1))
  printf 'not ok %s - %s\n' "$TEST_COUNT" "$1" >&2
  exit 1
}

ok() {
  TEST_COUNT=$((TEST_COUNT + 1))
  printf 'ok %s - %s\n' "$TEST_COUNT" "$1"
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

write_fixture() {
  printf '%s\n' "$2" > "$1"
}

count_exact_line() {
  $AWK -v expected="$2" '$0 == expected { count++ } END { print count + 0 }' "$1"
}

AWK=${AWK:-awk}
SED=${SED:-sed}
MOD_ID=fix_Surfing_Dns_ikuuu
DATA_DIR=$TEST_TMP
BACKUP_DIR=$TEST_TMP
AGH_RULES_ADDED=$TEST_TMP/no_previous_rules
AGH_PROXY_GROUP=DNS连接

log_msg() { :; }
print_out() { printf '%s\n' "$1" >&2; }
is_valid_ipv4() {
  printf '%s\n' "$1" | $AWK -F. '
    NF != 4 { exit 1 }
    { for (i = 1; i <= 4; i++) if ($i !~ /^[0-9]+$/ || $i + 0 > 255) exit 1 }
  '
}

. "$TEST_REPO/common/agh_fix.sh"

# Settings are data: preserve unrelated settings and never evaluate shell text.
write_fixture "$TEST_TMP/settings.original" 'enable_iptables=false
redir_port=51248
adg_user=root
adg_group=net_admin
startup_timeout=120'
assert_equal 'read unquoted group' net_admin "$(agh_setting_value "$TEST_TMP/settings.original" adg_group)"

write_fixture "$TEST_TMP/settings.quoted" '  adg_group="inet" # keep this comment'
assert_equal 'read double-quoted group with comment' inet "$(agh_setting_value "$TEST_TMP/settings.quoted" adg_group)"
write_fixture "$TEST_TMP/settings.single_quoted" "adg_group='3003'"
assert_equal 'read single-quoted numeric group' 3003 "$(agh_setting_value "$TEST_TMP/settings.single_quoted" adg_group)"

write_fixture "$TEST_TMP/settings.duplicate" 'adg_group=net_admin
adg_group=inet'
expect_failure 'reject duplicate group assignments' agh_setting_value "$TEST_TMP/settings.duplicate" adg_group
write_fixture "$TEST_TMP/settings.missing" 'adg_user=root'
expect_failure 'reject missing group instead of silently choosing a default' agh_setting_value "$TEST_TMP/settings.missing" adg_group
write_fixture "$TEST_TMP/settings.substitution" 'adg_group=$(id)'
expect_failure 'reject shell substitution as a group value' agh_setting_value "$TEST_TMP/settings.substitution" adg_group
write_fixture "$TEST_TMP/settings.command" 'adg_group=inet; echo unexpected'
expect_failure 'reject appended shell command as a group value' agh_setting_value "$TEST_TMP/settings.command" adg_group

expect_success 'write only the group assignment' agh_write_group "$TEST_TMP/settings.original" inet "$TEST_TMP/settings.modified"
write_fixture "$TEST_TMP/settings.expected" 'enable_iptables=false
redir_port=51248
adg_user=root
adg_group=inet
startup_timeout=120'
assert_file_equal 'group update preserves every other setting' "$TEST_TMP/settings.expected" "$TEST_TMP/settings.modified"
expect_failure 'group update refuses an ambiguous settings file' agh_write_group "$TEST_TMP/settings.duplicate" inet "$TEST_TMP/settings.invalid"
expect_failure 'group update rejects an unrelated target group' agh_write_group "$TEST_TMP/settings.original" shell "$TEST_TMP/settings.unknown_group"

write_fixture "$TEST_TMP/group.backup" '  adg_group="net_admin" # original formatting'
write_fixture "$TEST_TMP/settings.user_changed" 'enable_iptables=false
redir_port=54545
adg_user=root
adg_group=inet
startup_timeout=180
user_added_setting=true'
expect_success 'restore the exact original group line' agh_restore_group "$TEST_TMP/settings.user_changed" "$TEST_TMP/group.backup" "$TEST_TMP/settings.restored"
write_fixture "$TEST_TMP/settings.restore_expected" 'enable_iptables=false
redir_port=54545
adg_user=root
  adg_group="net_admin" # original formatting
startup_timeout=180
user_added_setting=true'
assert_file_equal 'restore preserves later user edits outside the group' "$TEST_TMP/settings.restore_expected" "$TEST_TMP/settings.restored"
write_fixture "$TEST_TMP/settings.numeric" 'adg_group=3003'
expect_success 'restore also recognizes the numeric inet group' agh_restore_group "$TEST_TMP/settings.numeric" "$TEST_TMP/group.backup" "$TEST_TMP/settings.numeric_restored"
assert_file_equal 'numeric group restoration retains exact original formatting' "$TEST_TMP/group.backup" "$TEST_TMP/settings.numeric_restored"
write_fixture "$TEST_TMP/settings.conflicting_group" 'adg_group=shell
user_added_setting=true'
expect_failure 'restore does not overwrite a later user-selected group' agh_restore_group "$TEST_TMP/settings.conflicting_group" "$TEST_TMP/group.backup" "$TEST_TMP/settings.conflicting_output"
write_fixture "$TEST_TMP/settings.already_original" 'adg_group=net_admin # restored by the user'
expect_success 'restore accepts an already-original group value' agh_restore_group "$TEST_TMP/settings.already_original" "$TEST_TMP/group.backup" "$TEST_TMP/settings.already_original_after"
assert_file_equal 'already-original group keeps the current comment' "$TEST_TMP/settings.already_original" "$TEST_TMP/settings.already_original_after"
write_fixture "$TEST_TMP/settings.original_alias" 'adg_group=3005 # equivalent group chosen by the user'
expect_success 'restore recognizes an already-original numeric alias' agh_restore_group "$TEST_TMP/settings.original_alias" "$TEST_TMP/group.backup" "$TEST_TMP/settings.original_alias_after"
assert_file_equal 'already-original group alias keeps the current comment' "$TEST_TMP/settings.original_alias" "$TEST_TMP/settings.original_alias_after"

# Inserting rules must neither claim existing user rules nor globally delete them.
write_fixture "$TEST_TMP/rules.base" 'mode: Rule
rules:
  # Existing routing policy
  - DST-PORT,53,DNS_Hijack
  - RULE-SET,CN_IP,DIRECT,no-resolve
  - MATCH,PROXY'
expect_failure 'unpatched rules are not considered ready' agh_rules_ready "$TEST_TMP/rules.base"
expect_success 'build the two priority rules' agh_build_rules "$TEST_TMP/rules.base" "$TEST_TMP/rules.patched" "$TEST_TMP/rules.added"
expect_success 'patched priority rules are ready' agh_rules_ready "$TEST_TMP/rules.patched"
assert_equal 'only the two inserted rules are recorded' 2 "$(wc -l < "$TEST_TMP/rules.added" | tr -d ' ')"
expect_success 'inserted rules carry module ownership markers' grep -qF "$MOD_ID" "$TEST_TMP/rules.added"
expect_success 'remove exactly the inserted rules' agh_remove_rules "$TEST_TMP/rules.patched" "$TEST_TMP/rules.added" "$TEST_TMP/rules.restored"
assert_file_equal 'apply and restore round-trip the original routing policy' "$TEST_TMP/rules.base" "$TEST_TMP/rules.restored"

AGH_RULES_ADDED=$TEST_TMP/rules.added
expect_success 'reapply an existing module patch' agh_build_rules "$TEST_TMP/rules.patched" "$TEST_TMP/rules.patched_again" "$TEST_TMP/rules.record_again"
assert_file_equal 'reapply does not duplicate or rewrite rules' "$TEST_TMP/rules.patched" "$TEST_TMP/rules.patched_again"
assert_file_equal 'reapply keeps the ownership record' "$TEST_TMP/rules.added" "$TEST_TMP/rules.record_again"
AGH_RULES_ADDED=$TEST_TMP/no_previous_rules

write_fixture "$TEST_TMP/rules.manual" 'rules:
  # The user previously applied the fix manually.
  - "IP-CIDR,120.53.53.53/32,DNS连接,no-resolve" # user rule B
  - '\''IP-CIDR,1.12.12.12/32,DNS连接,no-resolve'\'' # user rule A
  - MATCH,PROXY'
expect_success 'manual priority rules with quotes and either order are ready' agh_rules_ready "$TEST_TMP/rules.manual"
expect_success 'accept an already manually fixed configuration' agh_build_rules "$TEST_TMP/rules.manual" "$TEST_TMP/rules.manual_after" "$TEST_TMP/rules.manual_record"
assert_file_equal 'existing manual rules remain byte-for-byte unchanged' "$TEST_TMP/rules.manual" "$TEST_TMP/rules.manual_after"
expect_success 'existing manual rules are not claimed by the module' test ! -s "$TEST_TMP/rules.manual_record"
expect_success 'an empty ownership record performs no deletion' agh_remove_rules "$TEST_TMP/rules.manual" "$TEST_TMP/rules.manual_record" "$TEST_TMP/rules.manual_restored"
assert_file_equal 'manual rules survive disable with no owned changes' "$TEST_TMP/rules.manual" "$TEST_TMP/rules.manual_restored"

write_fixture "$TEST_TMP/rules.partial" 'rules:
  - IP-CIDR,1.12.12.12/32,DNS连接,no-resolve # existing user rule
  - RULE-SET,CN_IP,DIRECT,no-resolve
  - MATCH,PROXY'
expect_success 'complete a partial manual fix' agh_build_rules "$TEST_TMP/rules.partial" "$TEST_TMP/rules.partial_after" "$TEST_TMP/rules.partial_record"
expect_success 'partial fix has both required priority rules' agh_rules_ready "$TEST_TMP/rules.partial_after"
assert_equal 'partial fix only records the missing priority rule' 1 "$(wc -l < "$TEST_TMP/rules.partial_record" | tr -d ' ')"
expect_success 'partial fix preserves the preexisting user rule' grep -qF '  - IP-CIDR,1.12.12.12/32,DNS连接,no-resolve # existing user rule' "$TEST_TMP/rules.partial_after"
expect_success 'restore a partial fix' agh_remove_rules "$TEST_TMP/rules.partial_after" "$TEST_TMP/rules.partial_record" "$TEST_TMP/rules.partial_restored"
assert_file_equal 'partial restoration preserves the original user rule' "$TEST_TMP/rules.partial" "$TEST_TMP/rules.partial_restored"

write_fixture "$TEST_TMP/rules.low_priority" 'rules:
  - RULE-SET,CN_IP,DIRECT,no-resolve
  - IP-CIDR,1.12.12.12/32,DNS连接,no-resolve
  - IP-CIDR,120.53.53.53/32,DNS连接,no-resolve
  - MATCH,PROXY'
expect_failure 'equivalent low-priority rules do not count as an active fix' agh_rules_ready "$TEST_TMP/rules.low_priority"
expect_success 'prepend effective rules without moving user rules' agh_build_rules "$TEST_TMP/rules.low_priority" "$TEST_TMP/rules.low_after" "$TEST_TMP/rules.low_record"
expect_success 'new priority rules precede the domestic rule' agh_rules_ready "$TEST_TMP/rules.low_after"
expect_success 'remove the priority additions' agh_remove_rules "$TEST_TMP/rules.low_after" "$TEST_TMP/rules.low_record" "$TEST_TMP/rules.low_restored"
assert_file_equal 'low-priority user rules survive restoration' "$TEST_TMP/rules.low_priority" "$TEST_TMP/rules.low_restored"

FIRST_MANAGED_RULE=$(head -n 1 "$TEST_TMP/rules.added")
$AWK -v wanted="$FIRST_MANAGED_RULE" '
  $0 == wanted { sub(/DNS连接/, "UserChangedProxy") }
  { print }
' "$TEST_TMP/rules.patched" > "$TEST_TMP/rules.user_edited"
expect_success 'restore after the user edits a module-added rule' agh_remove_rules "$TEST_TMP/rules.user_edited" "$TEST_TMP/rules.added" "$TEST_TMP/rules.user_edited_restored"
expect_success 'an edited rule is kept instead of silently discarded' grep -qF 'UserChangedProxy' "$TEST_TMP/rules.user_edited_restored"
expect_failure 'an unchanged recorded rule has no ownership conflict' agh_rules_conflict "$TEST_TMP/rules.patched" "$TEST_TMP/rules.added"
expect_success 'an edited rule retaining the module marker is a conflict' agh_rules_conflict "$TEST_TMP/rules.user_edited" "$TEST_TMP/rules.added"
expect_failure 'ordinary unmarked manual rules are not a module conflict' agh_rules_conflict "$TEST_TMP/rules.manual" "$TEST_TMP/rules.manual_record"

$AWK -v duplicate="$FIRST_MANAGED_RULE" '
  /^rules:/ { print; print duplicate; next }
  { print }
' "$TEST_TMP/rules.patched" > "$TEST_TMP/rules.user_duplicated"
expect_success 'restore after an exact extra rule copy is added' agh_remove_rules "$TEST_TMP/rules.user_duplicated" "$TEST_TMP/rules.added" "$TEST_TMP/rules.user_duplicated_restored"
assert_equal 'remove at most the recorded occurrence, not every exact copy' 1 "$(count_exact_line "$TEST_TMP/rules.user_duplicated_restored" "$FIRST_MANAGED_RULE")"

write_fixture "$TEST_TMP/rules.flow" 'rules: ["MATCH,PROXY"]'
expect_failure 'reject unsupported inline rules instead of corrupting YAML' agh_build_rules "$TEST_TMP/rules.flow" "$TEST_TMP/rules.flow_after" "$TEST_TMP/rules.flow_record"
write_fixture "$TEST_TMP/rules.duplicate_blocks" 'rules:
  - MATCH,PROXY
rules:
  - MATCH,DIRECT'
expect_failure 'reject duplicate rules blocks' agh_build_rules "$TEST_TMP/rules.duplicate_blocks" "$TEST_TMP/rules.duplicate_after" "$TEST_TMP/rules.duplicate_record"

# IP-format encrypted upstreams avoid a new bootstrap dependency on AGH itself.
write_fixture "$TEST_TMP/upstreams.valid" 'dns:
  upstream_dns:
    - https://1.12.12.12/dns-query
    - https://120.53.53.53:443/dns-query
  upstream_dns_file: ""
  bootstrap_dns:
    - 180.184.1.1
    - 180.184.2.2
  fallback_dns:
    - https://101.226.4.6/dns-query'
expect_success 'accept the supported DNSPod IP DoH configuration' agh_upstreams_compatible "$TEST_TMP/upstreams.valid"
write_fixture "$TEST_TMP/upstreams.single" 'dns:
  upstream_dns:
    - https://1.12.12.12:443/dns-query
  upstream_dns_file: ""
  fallback_dns: []'
expect_success 'accept a single supported DNSPod IP upstream' agh_upstreams_compatible "$TEST_TMP/upstreams.single"
write_fixture "$TEST_TMP/upstreams.domain" 'dns:
  upstream_dns:
    - https://doh.pub/dns-query
  upstream_dns_file: ""'
expect_failure 'reject a domain upstream requiring bootstrap after changing GID' agh_upstreams_compatible "$TEST_TMP/upstreams.domain"
write_fixture "$TEST_TMP/upstreams.domain_fallback" 'dns:
  upstream_dns:
    - https://1.12.12.12/dns-query
  fallback_dns:
    - tls://dns.google'
expect_failure 'reject a fallback with the same bootstrap loop risk' agh_upstreams_compatible "$TEST_TMP/upstreams.domain_fallback"
write_fixture "$TEST_TMP/upstreams.udp" 'dns:
  upstream_dns:
    - https://1.12.12.12/dns-query
    - 223.5.5.5'
expect_failure 'reject a plain DNS upstream that may be redirected back to AGH' agh_upstreams_compatible "$TEST_TMP/upstreams.udp"
write_fixture "$TEST_TMP/upstreams.file" 'dns:
  upstream_dns:
    - https://1.12.12.12/dns-query
  upstream_dns_file: /data/adb/agh/custom-upstreams.txt'
expect_failure 'reject external upstream files whose dependencies were not inspected' agh_upstreams_compatible "$TEST_TMP/upstreams.file"
write_fixture "$TEST_TMP/upstreams.flow" 'dns:
  upstream_dns: [https://1.12.12.12/dns-query]'
expect_failure 'reject unsupported inline upstream lists' agh_upstreams_compatible "$TEST_TMP/upstreams.flow"
write_fixture "$TEST_TMP/upstreams.other" 'dns:
  upstream_dns:
    - https://8.8.8.8/dns-query'
expect_failure 'do not change AGH routing for an unrelated upstream configuration' agh_upstreams_compatible "$TEST_TMP/upstreams.other"
write_fixture "$TEST_TMP/upstreams.invalid_ipv4" 'dns:
  upstream_dns:
    - https://1.12.12.12/dns-query
  fallback_dns:
    - https://256.12.12.12/dns-query'
expect_failure 'reject invalid IPv4 octets instead of treating them as safe literal endpoints' agh_upstreams_compatible "$TEST_TMP/upstreams.invalid_ipv4"
write_fixture "$TEST_TMP/upstreams.custom_port" 'dns:
  upstream_dns:
    - https://1.12.12.12:8443/dns-query'
expect_failure 'reject an unverified DoH port' agh_upstreams_compatible "$TEST_TMP/upstreams.custom_port"
write_fixture "$TEST_TMP/upstreams.mixed" 'dns:
  upstream_dns:
    - https://1.12.12.12/dns-query
    - https://dns.google/dns-query'
expect_failure 'reject a mixed IP and hostname upstream configuration' agh_upstreams_compatible "$TEST_TMP/upstreams.mixed"

# Proxy policy selection is resolved through nested groups, not label guesses.
MOCK_PROXY_REQUESTS=$TEST_TMP/proxy.requests
MOCK_PROXY_CASE=simple_ss
AGH_STATUS=inactive
agh_api_get() {
  printf '%s\n' "$1" >> "$MOCK_PROXY_REQUESTS"
  case "$MOCK_PROXY_CASE:$1" in
    simple_ss:/proxies/DNS%E8%BF%9E%E6%8E%A5)
      printf '{"type":"Selector","now":"NodeA"}\n' ;;
    simple_ss:/proxies/NodeA)
      printf '{"type":"Shadowsocks"}\n' ;;
    nested_direct:/proxies/DNS%E8%BF%9E%E6%8E%A5|cyclic:/proxies/DNS%E8%BF%9E%E6%8E%A5)
      printf '{"type":"Selector","now":"GroupA"}\n' ;;
    nested_direct:/proxies/GroupA)
      printf '{"type":"Selector","now":"DIRECT"}\n' ;;
    cyclic:/proxies/GroupA)
      printf '{"type":"Selector","now":"DNS连接"}\n' ;;
    provider_ok:/proxies/DNS%E8%BF%9E%E6%8E%A5|provider_fail:/proxies/DNS%E8%BF%9E%E6%8E%A5)
      printf '{"type":"Selector","now":"ProviderNode"}\n' ;;
    provider_ok:/proxies/ProviderNode|provider_fail:/proxies/ProviderNode)
      printf '{"message":"Resource not found"}\n' ;;
    provider_ok:/proxies/DNS%E8%BF%9E%E6%8E%A5/delay\?*)
      printf '{"delay":83}\n' ;;
    provider_fail:/proxies/DNS%E8%BF%9E%E6%8E%A5/delay\?*)
      printf '{"message":"Timeout"}\n' ;;
    *) printf '{"message":"Unexpected fixture endpoint"}\n'; return 1 ;;
  esac
}
: > "$MOCK_PROXY_REQUESTS"
expect_success 'a real Shadowsocks leaf is an acceptable proxy selection' agh_proxy_selected
MOCK_PROXY_CASE=nested_direct
expect_failure 'a nested group selecting DIRECT is rejected' agh_proxy_selected
assert_equal 'nested DIRECT rejection has a useful status' requires_proxy_selection "$AGH_STATUS"
MOCK_PROXY_CASE=cyclic
expect_failure 'a cyclic proxy-group selection is rejected' agh_proxy_selected
assert_equal 'proxy selection cycle has a useful status' cyclic_proxy_selection "$AGH_STATUS"
MOCK_PROXY_CASE=provider_ok
: > "$MOCK_PROXY_REQUESTS"
expect_success 'a provider-backed display name requires a successful group probe' agh_proxy_selected
expect_success 'provider fallback probes the actual DNSPod DoH URL' grep -qF '/delay?timeout=4000&url=https%3A%2F%2F1.12.12.12%2Fdns-query%3Fdns%3D' "$MOCK_PROXY_REQUESTS"
MOCK_PROXY_CASE=provider_fail
expect_failure 'a provider node without a successful DoH probe is rejected' agh_proxy_selected
assert_equal 'unreachable provider selection has a useful status' unknown_or_unreachable_proxy "$AGH_STATUS"

printf '1..%s\n' "$TEST_COUNT"
