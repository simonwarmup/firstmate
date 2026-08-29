#!/usr/bin/env bash
# Behavior tests for fm-claude-quota.sh, the non-interactive Claude quota
# reader. The network is stubbed with a fakebin `curl` that plays back
# captured anthropic-ratelimit-unified-* header fixtures, so these stay
# hermetic: no ports, no real /v1/messages call, deterministic in CI.
#
# The cases that matter most are the two the report's own defensive-parsing
# warning calls out: a response that carries only a subset of the documented
# headers (a different account/plan) must report the missing ones as
# "unknown", never as zero and never as a hard failure; and a response
# carrying an unrecognised header must not break parsing of the rest.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-claude-quota.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-quota)

# A fakebin `curl` that plays back a fixed response: HTTP code from
# FAKE_HTTP_CODE (default 200), headers copied verbatim from the file at
# FAKE_HEADERS_FIXTURE (or an empty header block when unset), and records
# every argv it was called with to FAKE_CURL_LOG so a case can assert on it
# (in particular, that the token never appears there).
make_fake_curl() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
dfile="" ofile=""
argv=$*
while [ $# -gt 0 ]; do
  case "$1" in
    -D) dfile=$2; shift 2 ;;
    -o) ofile=$2; shift 2 ;;
    -w) shift 2 ;;
    -m|-X) shift 2 ;;
    -H)
      case "$2" in
        @*) : > /dev/null ;;
      esac
      shift 2
      ;;
    --data-binary) shift 2 ;;
    -sS) shift ;;
    https://*) shift ;;
    *) shift ;;
  esac
done
if [ -n "${FAKE_CURL_LOG:-}" ]; then
  printf 'argv=%s\n' "$argv" >> "$FAKE_CURL_LOG"
fi
if [ -n "$dfile" ]; then
  if [ -n "${FAKE_HEADERS_FIXTURE:-}" ]; then
    cp "$FAKE_HEADERS_FIXTURE" "$dfile"
  else
    printf 'HTTP/1.1 %s\n' "${FAKE_HTTP_CODE:-200}" > "$dfile"
  fi
fi
[ -n "$ofile" ] && printf '%s' "${FAKE_BODY:-{\}}" > "$ofile"
printf '%s' "${FAKE_HTTP_CODE:-200}"
exit "${FAKE_CURL_EXIT:-0}"
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

FULL_FIXTURE="$TMP_ROOT/full-headers.txt"
cat > "$FULL_FIXTURE" <<'H'
HTTP/1.1 200 OK
anthropic-ratelimit-unified-status: allowed_warning
anthropic-ratelimit-unified-5h-status: allowed
anthropic-ratelimit-unified-5h-reset: 1788020400
anthropic-ratelimit-unified-5h-utilization: 0.13
anthropic-ratelimit-unified-7d-status: allowed_warning
anthropic-ratelimit-unified-7d-reset: 1788098400
anthropic-ratelimit-unified-7d-utilization: 0.94
anthropic-ratelimit-unified-7d-surpassed-threshold: 0.75
anthropic-ratelimit-unified-overage-status: rejected
anthropic-ratelimit-unified-overage-reset: 1788220800
anthropic-ratelimit-unified-overage-utilization: 1.05
anthropic-ratelimit-unified-overage-surpassed-threshold: 1.0
anthropic-ratelimit-unified-representative-claim: seven_day
anthropic-ratelimit-unified-overage-disabled-reason: org_spend_cap_reached
anthropic-ratelimit-unified-upgrade-paths: overage
H

# Only the 5-hour window, as a different plan/account might return - no 7d,
# no overage - plus one header this parser has never heard of.
SUBSET_FIXTURE="$TMP_ROOT/subset-headers.txt"
cat > "$SUBSET_FIXTURE" <<'H'
HTTP/1.1 200 OK
anthropic-ratelimit-unified-status: allowed
anthropic-ratelimit-unified-5h-status: allowed
anthropic-ratelimit-unified-5h-reset: 1788020400
anthropic-ratelimit-unified-5h-utilization: 0.02
anthropic-ratelimit-unified-slow-budget-utilization: 0.10
H

# 2xx but no anthropic-ratelimit-unified-* headers of any kind: the probe
# malfunctioned (wrong endpoint, contract change), not "this plan has fewer
# meters", so this must be a hard failure rather than an all-"unknown" line.
EMPTY_FIXTURE="$TMP_ROOT/no-ratelimit-headers.txt"
cat > "$EMPTY_FIXTURE" <<'H'
HTTP/1.1 200 OK
content-type: application/json
H

test_no_token_fails_closed_with_no_curl_call() {
  local home fakebin log out rc
  home="$TMP_ROOT/no-token"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  out=$(PATH="$fakebin:$BASE_PATH" env -u CLAUDE_CODE_OAUTH_TOKEN FAKE_CURL_LOG="$log" "$SCRIPT" 2>&1)
  rc=$?
  expect_code 1 "$rc" "missing token must fail closed"
  assert_not_contains "$out" "=" "no token -> no key=value line, not even a fabricated unknown one"
  assert_absent "$log" "missing token must never reach curl"
  pass "no token fails closed before any network call"
}

test_full_headers_parse_and_distinguish_seat_from_spend_cap() {
  local home fakebin out
  home="$TMP_ROOT/full"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token FAKE_HEADERS_FIXTURE="$FULL_FIXTURE" "$SCRIPT")
  assert_contains "$out" "unified_status=allowed_warning" "top-level status"
  assert_contains "$out" "five_hour_utilization=0.13" "5h window"
  assert_contains "$out" "seven_day_utilization=0.94" "seat/weekly window (7d)"
  assert_contains "$out" "seven_day_surpassed_threshold=0.75" "seat threshold"
  assert_contains "$out" "overage_utilization=1.05" "spend cap (overage), distinct from seven_day_utilization"
  assert_contains "$out" "overage_disabled_reason=org_spend_cap_reached" "spend cap reason"
  assert_not_contains "$out" "overage_utilization=0.94" "overage must never be conflated with the seat window's value"
  pass "full header set parses, keeping the seat window and spend cap distinct"
}

test_subset_headers_report_missing_meters_as_unknown_not_zero() {
  local home fakebin out
  home="$TMP_ROOT/subset"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token FAKE_HEADERS_FIXTURE="$SUBSET_FIXTURE" "$SCRIPT")
  assert_contains "$out" "five_hour_utilization=0.02" "the meter this fixture does carry still parses"
  assert_contains "$out" "seven_day_status=unknown" "an absent meter reads unknown"
  assert_not_contains "$out" "seven_day_status=0" "an absent meter must never read as a fabricated zero"
  assert_contains "$out" "overage_status=unknown" "the other absent meter also reads unknown"
  assert_contains "$out" "overage_disabled_reason=unknown" "an absent reason field reads unknown too"
  pass "a plan-limited header subset reports missing meters as unknown, not zero, not a failure"
}

test_unrecognised_header_does_not_break_parsing() {
  local home fakebin out
  home="$TMP_ROOT/unrecognised"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token FAKE_HEADERS_FIXTURE="$SUBSET_FIXTURE" "$SCRIPT")
  assert_contains "$out" "five_hour_status=allowed" "a header this parser has never heard of must not block the ones it does know"
  pass "an unrecognised header is ignored rather than breaking the read"
}

test_no_ratelimit_headers_at_all_is_a_hard_failure() {
  local home fakebin out rc
  home="$TMP_ROOT/empty-headers"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token FAKE_HEADERS_FIXTURE="$EMPTY_FIXTURE" "$SCRIPT" 2>&1)
  rc=$?
  expect_code 1 "$rc" "a 2xx with zero ratelimit headers is a probe failure, not an all-unknown reading"
  assert_not_contains "$out" "=" "a probe failure must never print any key=value line"
  pass "a 2xx response carrying none of the unified headers fails closed instead of faking an unknown reading"
}

test_http_error_fails_closed() {
  local home fakebin out rc
  home="$TMP_ROOT/http-error"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token FAKE_HTTP_CODE=403 FAKE_BODY='{"error":"scope"}' "$SCRIPT" 2>&1)
  rc=$?
  expect_code 1 "$rc" "a non-2xx response must fail closed"
  assert_not_contains "$out" "=" "a non-2xx response must never print any key=value line"
  pass "a non-2xx HTTP response fails closed"
}

test_curl_transport_failure_fails_closed() {
  local home fakebin out rc
  home="$TMP_ROOT/curl-fail"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token FAKE_CURL_EXIT=28 "$SCRIPT" 2>&1)
  rc=$?
  expect_code 1 "$rc" "a curl transport failure (e.g. timeout) must fail closed"
  assert_not_contains "$out" "=" "a transport failure must never print any key=value line"
  pass "a curl transport failure (timeout, DNS, etc.) fails closed"
}

test_token_never_appears_in_curl_argv() {
  local home fakebin log
  home="$TMP_ROOT/no-argv-leak"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN='super-secret-token-value' FAKE_CURL_LOG="$log" FAKE_HEADERS_FIXTURE="$FULL_FIXTURE" "$SCRIPT" >/dev/null
  assert_present "$log" "the fake curl must have been invoked"
  assert_no_grep "super-secret-token-value" "$log" "the token must never appear in curl's argv (a ps snapshot must never see it)"
  pass "the OAuth token never appears in curl's argv"
}

test_help_does_not_require_a_token() {
  local out rc
  out=$(env -u CLAUDE_CODE_OAUTH_TOKEN "$SCRIPT" --help 2>&1)
  rc=$?
  expect_code 0 "$rc" "--help must succeed with no token set"
  assert_contains "$out" "Usage:" "help text names its usage"
  pass "--help works without a token or a network call"
}

test_bad_timeout_is_a_usage_error() {
  local out rc
  out=$(CLAUDE_CODE_OAUTH_TOKEN=fake-token "$SCRIPT" --timeout 0 2>&1)
  rc=$?
  expect_code 2 "$rc" "a timeout of 0 is out of the documented 1..60 range"
  assert_contains "$out" "--timeout" "usage error names the offending option"
  pass "an out-of-range --timeout is rejected before any network call"
}

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

test_no_token_fails_closed_with_no_curl_call
test_full_headers_parse_and_distinguish_seat_from_spend_cap
test_subset_headers_report_missing_meters_as_unknown_not_zero
test_unrecognised_header_does_not_break_parsing
test_no_ratelimit_headers_at_all_is_a_hard_failure
test_http_error_fails_closed
test_curl_transport_failure_fails_closed
test_token_never_appears_in_curl_argv
test_help_does_not_require_a_token
test_bad_timeout_is_a_usage_error
