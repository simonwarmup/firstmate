#!/usr/bin/env bash
# Behavior tests for fm-claude-quota.sh, the non-interactive Claude quota
# reader. The network is stubbed with a fakebin `curl` that plays back
# captured anthropic-ratelimit-unified-* header fixtures, so these stay
# hermetic: no ports, no real /v1/messages call, deterministic in CI.
#
# The cases that matter most: a response that carries only a subset of the
# documented headers (a different account/plan) must report the missing
# ones as "unknown", never zero, never a hard failure; a response carrying
# an unrecognised header must not break parsing of the rest; a malformed
# header value (non-numeric utilization, non-integer reset, a negative
# utilization) must read "unknown" rather than pass through as a fabricated
# reading; and - the finding a 2026-08-29 adversarial review raised - a
# non-2xx response that still carries the unified headers (the exact state
# a rate-limited or rejected call is in) must be parsed and emitted, not
# discarded, while a non-2xx response carrying no meters at all must still
# fail closed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-claude-quota.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-quota)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# A fakebin `curl` that plays back a fixed response: HTTP code from
# FAKE_HTTP_CODE (default 200), headers copied verbatim from the file at
# FAKE_HEADERS_FIXTURE (or an empty header block when unset). Records every
# argv it was called with to FAKE_CURL_LOG (token-leak proof), the exact
# request body to FAKE_CURL_BODY_LOG (proves the ~9-token max_tokens=1
# shape - A9), and the auth header temp file's permission mode to
# FAKE_CURL_AUTH_MODE_LOG (proves it is 0600 while curl can see it - A10).
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
    -m|-X|-A) shift 2 ;;
    -H)
      case "$2" in
        @*)
          authfile=${2#@}
          if [ -n "${FAKE_CURL_AUTH_MODE_LOG:-}" ] && [ -f "$authfile" ]; then
            { stat -f '%Lp' "$authfile" 2>/dev/null || stat -c '%a' "$authfile" 2>/dev/null; } \
              >> "$FAKE_CURL_AUTH_MODE_LOG"
          fi
          ;;
      esac
      shift 2
      ;;
    --data-binary)
      case "$2" in
        @*)
          bodyfile=${2#@}
          [ -n "${FAKE_CURL_BODY_LOG:-}" ] && [ -f "$bodyfile" ] && cat "$bodyfile" >> "$FAKE_CURL_BODY_LOG"
          ;;
      esac
      shift 2
      ;;
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

# The full set again, plus one header this parser has never heard of and
# never will - proves an unrecognised header does not break parsing of every
# real one alongside it (distinct from the missing-headers case below).
UNRECOGNISED_FIXTURE="$TMP_ROOT/unrecognised-header.txt"
cat "$FULL_FIXTURE" > "$UNRECOGNISED_FIXTURE"
printf 'anthropic-ratelimit-unified-completely-invented-field: 42\n' >> "$UNRECOGNISED_FIXTURE"

# Only the 5-hour window, as a different plan/account might return - no 7d,
# no overage.
SUBSET_FIXTURE="$TMP_ROOT/subset-headers.txt"
cat > "$SUBSET_FIXTURE" <<'H'
HTTP/1.1 200 OK
anthropic-ratelimit-unified-status: allowed
anthropic-ratelimit-unified-5h-status: allowed
anthropic-ratelimit-unified-5h-reset: 1788020400
anthropic-ratelimit-unified-5h-utilization: 0.02
H

# No anthropic-ratelimit-unified-* headers of any kind: the probe
# malfunctioned (wrong endpoint, contract change), not "this plan has fewer
# meters", so this must be a hard failure regardless of HTTP status.
EMPTY_FIXTURE="$TMP_ROOT/no-ratelimit-headers.txt"
cat > "$EMPTY_FIXTURE" <<'H'
HTTP/1.1 200 OK
content-type: application/json
H

# Header values with the exact shapes B4 requires "unknown", not a
# fabricated pass-through: non-numeric utilization, a negative utilization,
# and a non-integer reset.
BAD_VALUES_FIXTURE="$TMP_ROOT/bad-values.txt"
cat > "$BAD_VALUES_FIXTURE" <<'H'
HTTP/1.1 200 OK
anthropic-ratelimit-unified-status: allowed
anthropic-ratelimit-unified-5h-utilization: not-a-number
anthropic-ratelimit-unified-5h-reset: yesterday
anthropic-ratelimit-unified-7d-utilization: -0.5
anthropic-ratelimit-unified-7d-reset: 1788098400
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
  assert_contains "$out" "probe_http_status=200" "the HTTP status this reading came from"
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

test_unrecognised_header_does_not_break_parsing_of_the_full_set() {
  local home fakebin out
  home="$TMP_ROOT/unrecognised"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token FAKE_HEADERS_FIXTURE="$UNRECOGNISED_FIXTURE" "$SCRIPT")
  assert_contains "$out" "five_hour_utilization=0.13" "an unrecognised header must not block a real one that arrives alongside it"
  assert_contains "$out" "seven_day_utilization=0.94" "seat window still parses"
  assert_contains "$out" "overage_utilization=1.05" "spend cap still parses"
  assert_contains "$out" "upgrade_paths=overage" "last documented field still parses"
  pass "an unrecognised header is ignored rather than breaking parsing of every real header alongside it"
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

test_non_2xx_without_headers_fails_closed() {
  local home fakebin out rc
  home="$TMP_ROOT/http-error-no-headers"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token FAKE_HTTP_CODE=403 FAKE_HEADERS_FIXTURE="$EMPTY_FIXTURE" FAKE_BODY='{"error":"scope"}' "$SCRIPT" 2>&1)
  rc=$?
  expect_code 1 "$rc" "a non-2xx response carrying no meters at all must fail closed"
  assert_not_contains "$out" "=" "a probe failure must never print any key=value line"
  assert_contains "$out" "403" "the failure message names the HTTP status it saw"
  pass "a non-2xx response carrying none of the unified headers fails closed"
}

test_non_2xx_with_full_headers_is_parsed_not_discarded() {
  local home fakebin out rc
  home="$TMP_ROOT/http-error-with-headers"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token FAKE_HTTP_CODE=429 FAKE_HEADERS_FIXTURE="$FULL_FIXTURE" "$SCRIPT")
  rc=$?
  expect_code 0 "$rc" "a rate-limited response that still carries a complete reading must not be discarded"
  assert_contains "$out" "probe_http_status=429" "the caller can see this reading arrived alongside a non-2xx"
  assert_contains "$out" "seven_day_utilization=0.94" "the seat reading survives"
  assert_contains "$out" "overage_status=rejected" "the spend cap reading survives - this is the state that matters most"
  pass "a 429/403 response carrying the unified headers is parsed and emitted, with probe_http_status recording the real status"
}

test_malformed_header_values_read_unknown_not_a_fabricated_reading() {
  local home fakebin out rc
  home="$TMP_ROOT/bad-values"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token FAKE_HEADERS_FIXTURE="$BAD_VALUES_FIXTURE" "$SCRIPT")
  rc=$?
  expect_code 0 "$rc" "malformed values degrade individual fields, they do not fail the whole probe"
  assert_contains "$out" "five_hour_utilization=unknown" "a non-numeric utilization must read unknown, not pass through"
  assert_not_contains "$out" "five_hour_utilization=not-a-number" "the raw garbage value must never be emitted"
  assert_contains "$out" "five_hour_reset=unknown" "a non-integer reset must read unknown"
  assert_not_contains "$out" "five_hour_reset=yesterday" "the raw garbage value must never be emitted"
  assert_contains "$out" "seven_day_utilization=unknown" "a negative utilization must read unknown, never a fabricated reading"
  assert_not_contains "$out" "seven_day_utilization=-0.5" "the raw negative value must never be emitted"
  assert_contains "$out" "seven_day_reset=1788098400" "a validly-shaped value in the same response still parses normally"
  pass "malformed *_utilization and *_reset values read unknown instead of passing through as a fabricated reading"
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

test_auth_header_file_is_mode_0600_while_curl_can_see_it() {
  local home fakebin modelog mode
  home="$TMP_ROOT/auth-mode"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  modelog="$home/auth-mode.log"
  PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token FAKE_CURL_AUTH_MODE_LOG="$modelog" FAKE_HEADERS_FIXTURE="$FULL_FIXTURE" "$SCRIPT" >/dev/null
  assert_present "$modelog" "the auth header temp file must have existed while curl ran"
  mode=$(head -n1 "$modelog")
  [ "$mode" = "600" ] || fail "auth header temp file must be mode 0600, was $mode"
  pass "the auth header temp file is mode 0600 for the whole time curl can see it"
}

test_temp_files_are_cleaned_up_after_a_run() {
  local home fakebin tmpdir before after
  home="$TMP_ROOT/cleanup"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  tmpdir="$home/tmp"; mkdir -p "$tmpdir"
  before=$(find "$tmpdir" -type f | wc -l | tr -d ' ')
  TMPDIR="$tmpdir" PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token FAKE_HEADERS_FIXTURE="$FULL_FIXTURE" "$SCRIPT" >/dev/null
  after=$(find "$tmpdir" -type f | wc -l | tr -d ' ')
  [ "$before" = "0" ] || fail "test setup bug: tmpdir was not empty before the run"
  [ "$after" = "0" ] || fail "temp files were left behind in TMPDIR after a normal run: $(find "$tmpdir" -type f)"
  pass "no temp file (auth header, body, response, headers) survives a normal run"
}

test_request_body_is_exactly_the_documented_max_tokens_1_shape() {
  local home fakebin bodylog body
  home="$TMP_ROOT/body-shape"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  bodylog="$home/body.log"
  PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token FAKE_CURL_BODY_LOG="$bodylog" FAKE_HEADERS_FIXTURE="$FULL_FIXTURE" "$SCRIPT" >/dev/null
  assert_present "$bodylog" "the request body must have been sent"
  body=$(cat "$bodylog")
  assert_contains "$body" '"max_tokens":1' "the documented ~9-token cost bound depends on max_tokens being exactly 1"
  assert_contains "$body" '"model":"claude-haiku-4-5-20251001"' "the default model actually reaches the request body"
  pass "the request body sent to curl is the documented max_tokens=1 shape on the default model"
}

test_model_rejects_characters_outside_the_documented_set() {
  local out rc
  out=$(CLAUDE_CODE_OAUTH_TOKEN=fake-token "$SCRIPT" --model 'claude-haiku-4-5-20251001","system":"injected' 2>&1)
  rc=$?
  expect_code 2 "$rc" "a --model value outside [A-Za-z0-9._-] must be rejected before any network call"
  assert_contains "$out" "--model" "usage error names the offending option"
  pass "a --model value that would break out of the request body's JSON string is rejected"
}

test_model_rejects_empty_value() {
  local out rc
  out=$(CLAUDE_CODE_OAUTH_TOKEN=fake-token "$SCRIPT" --model '' 2>&1)
  rc=$?
  expect_code 2 "$rc" "an empty --model value must be rejected"
  assert_contains "$out" "--model" "usage error names the offending option"
  pass "an empty --model value is rejected"
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

test_no_token_fails_closed_with_no_curl_call
test_full_headers_parse_and_distinguish_seat_from_spend_cap
test_subset_headers_report_missing_meters_as_unknown_not_zero
test_unrecognised_header_does_not_break_parsing_of_the_full_set
test_no_ratelimit_headers_at_all_is_a_hard_failure
test_non_2xx_without_headers_fails_closed
test_non_2xx_with_full_headers_is_parsed_not_discarded
test_malformed_header_values_read_unknown_not_a_fabricated_reading
test_curl_transport_failure_fails_closed
test_token_never_appears_in_curl_argv
test_auth_header_file_is_mode_0600_while_curl_can_see_it
test_temp_files_are_cleaned_up_after_a_run
test_request_body_is_exactly_the_documented_max_tokens_1_shape
test_model_rejects_characters_outside_the_documented_set
test_model_rejects_empty_value
test_help_does_not_require_a_token
test_bad_timeout_is_a_usage_error
