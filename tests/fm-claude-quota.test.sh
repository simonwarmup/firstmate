#!/usr/bin/env bash
# Behavior tests for fm-claude-quota.sh, the non-interactive Claude quota
# reader. The network is stubbed with a fakebin `curl` that plays back
# captured anthropic-ratelimit-unified-* header fixtures, so these stay
# hermetic: no ports, no real /v1/messages call, deterministic in CI.
#
# A 2026-08-29 adversarial review round found that fixing exactly what a
# reviewer named, without sweeping the same defect CLASS elsewhere, leaves an
# identical hole one function later - a can't-fail transport-failure test
# right next to the can't-fail HTTP-error test that had already been fixed.
# So every fixture here is built with real CRLF line endings and an
# HTTP/2-style status line (the live API's actual wire format - all-LF,
# HTTP/1.1 fixtures never exercised the CR-strip every emitted value depends
# on), at least one mixed-case header name (the live wire format lowercases
# everything, but a proxy or intermediary need not, so the case-insensitive
# match is tested independently of what this one account happens to send),
# and every guard in the script - not a sample of the ones a reviewer
# happened to name - has a fixture/assertion pair that would fail if that
# guard were deleted (recorded in the sweep notes in the PR description).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-claude-quota.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-quota)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# assert_kv_line <haystack> <line> <msg>: <line> must appear as a whole line
# in <haystack> - not merely as a substring, which is the unanchored-match
# shape a 2026-08-30 review round showed lets a script sending
# "max_tokens":16384 pass an assertion for "max_tokens":1 (BLOCK-1), and
# would equally let "unmapped_unified_headers=1" pass for a real value of 10.
# $out has a real newline between every emitted field, so a plain per-line
# exact match is both correct and simple - no regex anchoring needed.
assert_kv_line() {
  printf '%s\n' "$1" | grep -qxF -- "$2" || fail "$3"$'\n'"--- output ---"$'\n'"$1"
}

# assert_not_kv_line: the negation of assert_kv_line.
assert_not_kv_line() {
  if printf '%s\n' "$1" | grep -qxF -- "$2"; then
    fail "$3"$'\n'"--- output ---"$'\n'"$1"
  fi
}

# crlf <lines...>: joins its arguments with real \r\n, terminated by \r\n,
# matching the live API's actual wire format (HTTP/2, CRLF - curl still
# writes CRLF into the -D file it hands us for an HTTP/2 response).
crlf() {
  local line
  for line in "$@"; do
    printf '%s\r\n' "$line"
  done
}

# A fakebin `curl` that plays back a fixed response: HTTP code from
# FAKE_HTTP_CODE (default 200), headers copied verbatim from the file at
# FAKE_HEADERS_FIXTURE (or an empty header block when unset). Records every
# argv it was called with to FAKE_CURL_LOG (token-leak proof and curl
# invocation safety proof), the exact request body to FAKE_CURL_BODY_LOG
# (proves the ~9-token max_tokens=1 shape - A9/AA5), and the auth header temp
# file's permission mode to FAKE_CURL_AUTH_MODE_LOG (proves it is 0600 while
# curl can see it - A10).
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
    printf 'HTTP/2 %s\r\n' "${FAKE_HTTP_CODE:-200}" > "$dfile"
  fi
fi
[ -n "$ofile" ] && printf '%s' "${FAKE_BODY:-{\}}" > "$ofile"
printf '%s' "${FAKE_HTTP_CODE:-200}"
exit "${FAKE_CURL_EXIT:-0}"
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

# make_no_curl_path <dir>: a fakebin symlinking every external tool this
# script actually calls EXCEPT curl (mktemp, chmod, grep, head, awk, rm,
# tail), so "command -v curl" genuinely fails rather than falling through to
# the real system curl - on macOS, curl and every one of those tools live in
# the same one or two system directories, so excluding curl by directory
# choice alone is not possible; excluding it tool-by-tool is.
make_no_curl_path() {
  local dir=$1 fakebin tool real
  fakebin=$(fm_fakebin "$dir")
  for tool in mktemp chmod grep head awk rm tail; do
    real=$(command -v "$tool" 2>/dev/null) || continue
    ln -s "$real" "$fakebin/$tool"
  done
  printf '%s\n' "$fakebin"
}

# The full documented set, as it is actually sent today: CRLF, HTTP/2, and
# one mixed-case header name (unified-status) proving the case-insensitive
# match independently of this account's own (all-lowercase) wire format.
FULL_FIXTURE="$TMP_ROOT/full-headers.txt"
crlf \
  'HTTP/2 200 ' \
  'Anthropic-Ratelimit-Unified-Status: allowed_warning' \
  'anthropic-ratelimit-unified-5h-status: allowed' \
  'anthropic-ratelimit-unified-5h-reset: 1788020400' \
  'anthropic-ratelimit-unified-5h-utilization: 0.13' \
  'anthropic-ratelimit-unified-7d-status: allowed_warning' \
  'anthropic-ratelimit-unified-7d-reset: 1788098400' \
  'anthropic-ratelimit-unified-7d-utilization: 0.94' \
  'anthropic-ratelimit-unified-7d-surpassed-threshold: 0.75' \
  'anthropic-ratelimit-unified-overage-status: rejected' \
  'anthropic-ratelimit-unified-overage-reset: 1788220800' \
  'anthropic-ratelimit-unified-overage-utilization: 1.05' \
  'anthropic-ratelimit-unified-overage-surpassed-threshold: 1.0' \
  'anthropic-ratelimit-unified-representative-claim: seven_day' \
  'anthropic-ratelimit-unified-overage-disabled-reason: org_spend_cap_reached' \
  'anthropic-ratelimit-unified-upgrade-paths: overage' \
  > "$FULL_FIXTURE"

# The full set again, plus the top-level reset and the newer fallback meter -
# both of which a live capture showed present on this account days after the
# investigation that built this script recorded them absent (AA4) - and one
# header this parser has never heard of and never will, to prove an
# unrecognised header does not break parsing of every real one alongside it.
UNRECOGNISED_FIXTURE="$TMP_ROOT/unrecognised-header.txt"
crlf \
  'HTTP/2 200 ' \
  'anthropic-ratelimit-unified-status: allowed_warning' \
  'anthropic-ratelimit-unified-reset: 1788098400' \
  'anthropic-ratelimit-unified-5h-status: allowed' \
  'anthropic-ratelimit-unified-5h-reset: 1788020400' \
  'anthropic-ratelimit-unified-5h-utilization: 0.13' \
  'anthropic-ratelimit-unified-7d-status: allowed_warning' \
  'anthropic-ratelimit-unified-7d-reset: 1788098400' \
  'anthropic-ratelimit-unified-7d-utilization: 0.94' \
  'anthropic-ratelimit-unified-7d-surpassed-threshold: 0.75' \
  'anthropic-ratelimit-unified-overage-status: rejected' \
  'anthropic-ratelimit-unified-overage-reset: 1788220800' \
  'anthropic-ratelimit-unified-overage-utilization: 1.05' \
  'anthropic-ratelimit-unified-overage-surpassed-threshold: 1.0' \
  'anthropic-ratelimit-unified-representative-claim: seven_day' \
  'anthropic-ratelimit-unified-overage-disabled-reason: org_spend_cap_reached' \
  'anthropic-ratelimit-unified-upgrade-paths: overage' \
  'anthropic-ratelimit-unified-fallback-percentage: 0.5' \
  'anthropic-ratelimit-unified-completely-invented-field: 42' \
  > "$UNRECOGNISED_FIXTURE"

# Only the 5-hour window, as a different plan/account might return - no 7d,
# no overage.
SUBSET_FIXTURE="$TMP_ROOT/subset-headers.txt"
crlf \
  'HTTP/2 200 ' \
  'anthropic-ratelimit-unified-status: allowed' \
  'anthropic-ratelimit-unified-5h-status: allowed' \
  'anthropic-ratelimit-unified-5h-reset: 1788020400' \
  'anthropic-ratelimit-unified-5h-utilization: 0.02' \
  > "$SUBSET_FIXTURE"

# No anthropic-ratelimit-unified-* headers of any kind: the probe
# malfunctioned (wrong endpoint, contract change), not "this plan has fewer
# meters", so this must be a hard failure regardless of HTTP status.
EMPTY_FIXTURE="$TMP_ROOT/no-ratelimit-headers.txt"
crlf 'HTTP/2 200 ' 'content-type: application/json' > "$EMPTY_FIXTURE"

# Header values with the exact shapes B4 requires "unknown", not a
# fabricated pass-through, mixed with one validly-shaped value so the
# reading as a whole still succeeds (only the individual bad fields degrade).
BAD_VALUES_FIXTURE="$TMP_ROOT/bad-values.txt"
crlf \
  'HTTP/2 200 ' \
  'anthropic-ratelimit-unified-status: allowed' \
  'anthropic-ratelimit-unified-5h-utilization: not-a-number' \
  'anthropic-ratelimit-unified-5h-reset: yesterday' \
  'anthropic-ratelimit-unified-7d-utilization: -0.5' \
  'anthropic-ratelimit-unified-7d-reset: 1788098400' \
  > "$BAD_VALUES_FIXTURE"

# Every numeric meter malformed and NOTHING validly shaped - this is BB2's
# proof case: headers are genuinely present (HEADER_HITS > 0) but nothing
# parses, so the reading must fail closed rather than exit 0 with every
# meter reading "unknown" (indistinguishable from a plan with fewer windows).
ALL_MALFORMED_FIXTURE="$TMP_ROOT/all-malformed.txt"
crlf \
  'HTTP/2 429 ' \
  'anthropic-ratelimit-unified-status: rejected' \
  'anthropic-ratelimit-unified-5h-utilization: nope' \
  'anthropic-ratelimit-unified-5h-reset: nope' \
  'anthropic-ratelimit-unified-7d-utilization: -1' \
  'anthropic-ratelimit-unified-7d-reset: 0' \
  'anthropic-ratelimit-unified-overage-utilization: garbage' \
  'anthropic-ratelimit-unified-overage-reset: garbage' \
  > "$ALL_MALFORMED_FIXTURE"

# Every real MEASUREMENT (*_utilization, *_reset) malformed, but a static
# threshold and the auxiliary fallback meter both parse validly - a 2026-08-30
# review showed an earlier version of the parsed-meter guard counted these
# two alongside real measurements, so this exact shape survived as a false
# exit-0 all-unknown-for-the-numbers-that-matter reading (ADV-4).
THRESHOLD_ONLY_FIXTURE="$TMP_ROOT/threshold-only.txt"
crlf \
  'HTTP/2 429 ' \
  'anthropic-ratelimit-unified-status: rejected' \
  'anthropic-ratelimit-unified-5h-utilization: nope' \
  'anthropic-ratelimit-unified-5h-reset: nope' \
  'anthropic-ratelimit-unified-7d-utilization: nope' \
  'anthropic-ratelimit-unified-7d-reset: nope' \
  'anthropic-ratelimit-unified-overage-utilization: nope' \
  'anthropic-ratelimit-unified-overage-reset: nope' \
  'anthropic-ratelimit-unified-overage-surpassed-threshold: 1.0' \
  'anthropic-ratelimit-unified-fallback-percentage: 0.5' \
  > "$THRESHOLD_ONLY_FIXTURE"

# Only raw fields (status, disabled_reason) present and valid - no
# *_utilization or *_reset header at all. This script deliberately fails
# closed here (ADV-5): a status with no number attached is not something a
# quota-aware caller can act on. Documented as a deliberate, unobserved-case
# choice, not a proven-necessary one - see the header comment.
RAW_ONLY_FIXTURE="$TMP_ROOT/raw-only.txt"
crlf \
  'HTTP/2 429 ' \
  'anthropic-ratelimit-unified-status: rejected' \
  'anthropic-ratelimit-unified-overage-disabled-reason: org_spend_cap_reached' \
  > "$RAW_ONLY_FIXTURE"

# The exact case AA3 proved: RFC 9110 permits trailing optional whitespace,
# and the live server's own status line carries one ("HTTP/2 200 ") - a
# trailing space before the CRLF must not turn a valid value into "unknown".
TRAILING_OWS_FIXTURE="$TMP_ROOT/trailing-ows.txt"
crlf \
  'HTTP/2 200 ' \
  'anthropic-ratelimit-unified-status: allowed' \
  'anthropic-ratelimit-unified-7d-utilization: 0.96 ' \
  > "$TRAILING_OWS_FIXTURE"

# The same header sent twice with different values - proves last-value-wins
# (fm_claude_quota_field's documented `tail -n1` behaviour) is real, not just
# documented (AA10).
DUPLICATE_HEADER_FIXTURE="$TMP_ROOT/duplicate-header.txt"
crlf \
  'HTTP/2 200 ' \
  'anthropic-ratelimit-unified-status: allowed' \
  'anthropic-ratelimit-unified-7d-utilization: 0.10' \
  'anthropic-ratelimit-unified-7d-utilization: 0.99' \
  > "$DUPLICATE_HEADER_FIXTURE"

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

test_token_with_newline_fails_closed_with_no_curl_call() {
  local home fakebin log out rc
  home="$TMP_ROOT/token-newline"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  out=$(PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=$'bad\ntoken' FAKE_CURL_LOG="$log" "$SCRIPT" 2>&1)
  rc=$?
  expect_code 1 "$rc" "a token containing a newline must fail closed"
  assert_not_contains "$out" "=" "a rejected token must never print any key=value line"
  assert_absent "$log" "a token containing a newline must never reach curl"
  pass "a token containing a newline is rejected before any network call"
}

test_curl_missing_fails_closed() {
  local home fakebin out rc
  home="$TMP_ROOT/no-curl"; mkdir -p "$home"
  fakebin=$(make_no_curl_path "$home")
  # Invoked as `bash "$SCRIPT"` rather than executed directly, so resolving
  # the shebang's /usr/bin/env is not itself a dependency of this case - the
  # thing under test is the script's own "curl is required" guard, not
  # whether /usr/bin/env is reachable.
  out=$(PATH="$fakebin" CLAUDE_CODE_OAUTH_TOKEN=fake-token "${BASH:-/bin/bash}" "$SCRIPT" 2>&1)
  rc=$?
  expect_code 1 "$rc" "a missing curl must fail closed before touching the token"
  assert_contains "$out" "curl is required and was not found on PATH" "the failure message must be this guard's own, not the transport-failure guard's (both mention the word curl)"
  assert_not_contains "$out" "curl exit" "this must be the curl-presence guard firing, not the transport-failure guard"
  pass "a PATH with no curl fails closed with a clear message"
}

test_timeout_rejects_non_numeric_value() {
  local out rc
  out=$(CLAUDE_CODE_OAUTH_TOKEN=fake-token "$SCRIPT" --timeout abc 2>&1)
  rc=$?
  expect_code 2 "$rc" "a non-numeric --timeout must be rejected before any network call"
  assert_contains "$out" "--timeout" "usage error names the offending option"
  pass "a non-numeric --timeout is rejected"
}

test_timeout_rejects_value_above_range() {
  local out rc
  out=$(CLAUDE_CODE_OAUTH_TOKEN=fake-token "$SCRIPT" --timeout 61 2>&1)
  rc=$?
  expect_code 2 "$rc" "a --timeout above the documented 1..60 range must be rejected"
  assert_contains "$out" "--timeout" "usage error names the offending option"
  pass "a --timeout above the documented range is rejected"
}

test_bad_timeout_is_a_usage_error() {
  local home fakebin out rc
  home="$TMP_ROOT/bad-timeout"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token "$SCRIPT" --timeout 0 2>&1)
  rc=$?
  expect_code 2 "$rc" "a timeout of 0 is out of the documented 1..60 range"
  assert_contains "$out" "--timeout" "usage error names the offending option"
  pass "an out-of-range --timeout is rejected before any network call"
}

test_full_headers_parse_and_distinguish_seat_from_spend_cap() {
  local home fakebin out
  home="$TMP_ROOT/full"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token FAKE_HEADERS_FIXTURE="$FULL_FIXTURE" "$SCRIPT")
  assert_kv_line "$out" "probe_http_status=200" "the HTTP status this reading came from"
  assert_kv_line "$out" "unified_status=allowed_warning" "top-level status, sent here under a mixed-case header name"
  assert_kv_line "$out" "five_hour_utilization=0.13" "5h window"
  assert_kv_line "$out" "seven_day_utilization=0.94" "seat/weekly window (7d)"
  assert_kv_line "$out" "seven_day_surpassed_threshold=0.75" "seat threshold"
  assert_kv_line "$out" "overage_utilization=1.05" "spend cap (overage), distinct from seven_day_utilization"
  assert_kv_line "$out" "overage_surpassed_threshold=1.0" "spend cap threshold - the other half of the seat/spend-cap pair (ADV-2): the utilization conflation alone was pinned, but not this one, so a mapping mistake between the two thresholds went unnoticed"
  assert_kv_line "$out" "overage_disabled_reason=org_spend_cap_reached" "spend cap reason"
  assert_kv_line "$out" "representative_claim=seven_day" "which window unified_status is keyed to (ADV-2: previously unpinned, so a mis-mapping to another field would not have been noticed)"
  assert_not_kv_line "$out" "overage_utilization=0.94" "overage must never be conflated with the seat window's value"
  assert_not_kv_line "$out" "overage_surpassed_threshold=0.75" "the spend-cap threshold must never be conflated with the seat threshold's value (ADV-2)"
  pass "full header set parses (mixed-case header name, real CRLF/HTTP2 wire format), keeping the seat window and spend cap distinct on both utilization and threshold"
}

test_unrecognised_header_does_not_break_parsing_of_the_full_set() {
  local home fakebin out
  home="$TMP_ROOT/unrecognised"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token FAKE_HEADERS_FIXTURE="$UNRECOGNISED_FIXTURE" "$SCRIPT")
  assert_kv_line "$out" "five_hour_utilization=0.13" "an unrecognised header must not block a real one that arrives alongside it"
  assert_kv_line "$out" "seven_day_utilization=0.94" "seat window still parses"
  assert_kv_line "$out" "overage_utilization=1.05" "spend cap still parses"
  assert_kv_line "$out" "upgrade_paths=overage" "a documented field still parses"
  assert_kv_line "$out" "unified_reset=1788098400" "a header this script did not originally name (AA4) is now parsed explicitly"
  assert_kv_line "$out" "fallback_percentage=0.5" "the newer fallback meter (AA4) is now parsed explicitly"
  assert_kv_line "$out" "unmapped_unified_headers=1" "the one genuinely unrecognised header is counted, not silently dropped with no signal (line-exact - an unanchored match here would also pass for a real count of 10)"
  assert_kv_line "$out" "unmapped_unified_header_names=completely-invented-field" "the unmapped header's own NAME is surfaced too (ADV-6) - a count alone was shown to go stale within hours of being written"
  pass "an unrecognised header is ignored rather than breaking parsing, and both its count and its name are surfaced rather than vanishing with no signal"
}

test_subset_headers_report_missing_meters_as_unknown_not_zero() {
  local home fakebin out
  home="$TMP_ROOT/subset"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token FAKE_HEADERS_FIXTURE="$SUBSET_FIXTURE" "$SCRIPT")
  assert_kv_line "$out" "five_hour_utilization=0.02" "the meter this fixture does carry still parses"
  assert_kv_line "$out" "seven_day_status=unknown" "an absent meter reads unknown"
  assert_not_kv_line "$out" "seven_day_status=0" "an absent meter must never read as a fabricated zero"
  assert_kv_line "$out" "overage_status=unknown" "the other absent meter also reads unknown"
  assert_kv_line "$out" "overage_disabled_reason=unknown" "an absent reason field reads unknown too"
  pass "a plan-limited header subset reports missing meters as unknown, not zero, not a failure"
}

test_no_ratelimit_headers_at_all_is_a_hard_failure() {
  local home fakebin out rc
  home="$TMP_ROOT/empty-headers"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token FAKE_HEADERS_FIXTURE="$EMPTY_FIXTURE" "$SCRIPT" 2>&1)
  rc=$?
  expect_code 1 "$rc" "a 2xx with zero ratelimit headers is a probe failure, not an all-unknown reading"
  assert_not_contains "$out" "=" "a probe failure must never print any key=value line"
  assert_contains "$out" "no anthropic-ratelimit-unified-* headers at all" "this must be the dedicated zero-headers guard, distinguishable from the separate zero-parsed-meters guard (BB2)"
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
  assert_contains "$out" "no anthropic-ratelimit-unified-* headers at all" "this must be the dedicated zero-headers guard, distinguishable from the separate zero-parsed-meters guard (BB2)"
  pass "a non-2xx response carrying none of the unified headers fails closed"
}

test_non_2xx_with_full_headers_is_parsed_not_discarded() {
  local home fakebin out rc
  home="$TMP_ROOT/http-error-with-headers"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token FAKE_HTTP_CODE=429 FAKE_HEADERS_FIXTURE="$FULL_FIXTURE" "$SCRIPT")
  rc=$?
  expect_code 0 "$rc" "a rate-limited response that still carries a complete reading must not be discarded"
  assert_kv_line "$out" "probe_http_status=429" "the caller can see this reading arrived alongside a non-2xx"
  assert_kv_line "$out" "seven_day_utilization=0.94" "the seat reading survives"
  assert_kv_line "$out" "overage_status=rejected" "the spend cap reading survives - this is the state that matters most"
  pass "a 429/403 response carrying the unified headers is parsed and emitted, with probe_http_status recording the real status"
}

test_headers_present_but_every_value_malformed_fails_closed() {
  local home fakebin out rc
  home="$TMP_ROOT/all-malformed"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token FAKE_HTTP_CODE=429 FAKE_HEADERS_FIXTURE="$ALL_MALFORMED_FIXTURE" "$SCRIPT" 2>&1)
  rc=$?
  expect_code 1 "$rc" "headers present but zero numeric meters usable must fail closed (BB2) rather than exit 0 all-unknown"
  assert_not_contains "$out" "=" "a probe failure must never print any key=value line"
  pass "a response carrying unified headers where every single numeric meter is malformed fails closed instead of a clean exit-0 all-unknown reading"
}

test_valid_threshold_and_fallback_do_not_rescue_all_malformed_measurements() {
  local home fakebin out rc
  home="$TMP_ROOT/threshold-only"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token FAKE_HTTP_CODE=429 FAKE_HEADERS_FIXTURE="$THRESHOLD_ONLY_FIXTURE" "$SCRIPT" 2>&1)
  rc=$?
  expect_code 1 "$rc" "a valid threshold or fallback_percentage must not count toward the parsed-meter guard when every real measurement is malformed (ADV-4)"
  assert_not_contains "$out" "=" "a probe failure must never print any key=value line"
  pass "a response where only a static threshold and the auxiliary fallback meter parse, with every real *_utilization/*_reset measurement malformed, still fails closed"
}

test_raw_fields_only_with_no_measurement_fails_closed() {
  local home fakebin out rc
  home="$TMP_ROOT/raw-only"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token FAKE_HTTP_CODE=429 FAKE_HEADERS_FIXTURE="$RAW_ONLY_FIXTURE" "$SCRIPT" 2>&1)
  rc=$?
  expect_code 1 "$rc" "a response with only raw fields (status, disabled_reason) and no *_utilization/*_reset header at all is a deliberate fail-closed case (ADV-5), documented as an unobserved-but-chosen behaviour"
  assert_not_contains "$out" "=" "a probe failure must never print any key=value line"
  pass "a response carrying only raw fields and no numeric measurement at all fails closed, per this script's documented (and deliberately conservative) choice"
}

test_malformed_header_values_read_unknown_not_a_fabricated_reading() {
  local home fakebin out rc
  home="$TMP_ROOT/bad-values"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token FAKE_HEADERS_FIXTURE="$BAD_VALUES_FIXTURE" "$SCRIPT")
  rc=$?
  expect_code 0 "$rc" "malformed values degrade individual fields, they do not fail the whole probe when at least one meter is usable"
  assert_kv_line "$out" "five_hour_utilization=unknown" "a non-numeric utilization must read unknown, not pass through"
  assert_not_kv_line "$out" "five_hour_utilization=not-a-number" "the raw garbage value must never be emitted"
  assert_kv_line "$out" "five_hour_reset=unknown" "a non-integer reset must read unknown"
  assert_not_kv_line "$out" "five_hour_reset=yesterday" "the raw garbage value must never be emitted"
  assert_kv_line "$out" "seven_day_utilization=unknown" "a negative utilization must read unknown, never a fabricated reading"
  assert_not_kv_line "$out" "seven_day_utilization=-0.5" "the raw negative value must never be emitted"
  assert_kv_line "$out" "seven_day_reset=1788098400" "a validly-shaped value in the same response still parses normally"
  pass "malformed *_utilization and *_reset values read unknown instead of passing through as a fabricated reading"
}

test_trailing_whitespace_on_a_header_value_still_parses() {
  local home fakebin out
  home="$TMP_ROOT/trailing-ows"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token FAKE_HEADERS_FIXTURE="$TRAILING_OWS_FIXTURE" "$SCRIPT")
  assert_kv_line "$out" "seven_day_utilization=0.96" "RFC 9110 permits trailing OWS on a header value; it must not turn a valid reading into unknown"
  assert_not_kv_line "$out" "seven_day_utilization=unknown" "trailing whitespace must not be read as malformed"
  pass "trailing whitespace on a header value is stripped, not read as malformed"
}

test_duplicate_header_last_value_wins() {
  local home fakebin out
  home="$TMP_ROOT/duplicate-header"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token FAKE_HEADERS_FIXTURE="$DUPLICATE_HEADER_FIXTURE" "$SCRIPT")
  assert_kv_line "$out" "seven_day_utilization=0.99" "a duplicated header must resolve to its last value, not its first"
  assert_not_kv_line "$out" "seven_day_utilization=0.10" "the earlier, superseded value must not win"
  pass "a duplicated header resolves to its last value"
}

test_curl_returns_non_numeric_http_status_fails_closed() {
  local home fakebin out rc
  home="$TMP_ROOT/bad-status"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token FAKE_HTTP_CODE=abc FAKE_HEADERS_FIXTURE="$FULL_FIXTURE" "$SCRIPT" 2>&1)
  rc=$?
  expect_code 1 "$rc" "a non-numeric HTTP status from curl's own -w output must fail closed"
  assert_not_contains "$out" "=" "a probe failure must never print any key=value line"
  pass "a non-numeric HTTP status is rejected even when headers are present"
}

test_curl_transport_failure_fails_closed() {
  local home fakebin out rc
  home="$TMP_ROOT/curl-fail"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token FAKE_CURL_EXIT=28 FAKE_HEADERS_FIXTURE="$FULL_FIXTURE" "$SCRIPT" 2>&1)
  rc=$?
  expect_code 1 "$rc" "a curl transport failure (e.g. timeout) must fail closed even when curl had already received a full header block before failing"
  assert_not_contains "$out" "=" "a transport failure must never print any key=value line"
  assert_contains "$out" "curl exit 28" "the failure message names the transport failure, so this cannot be confused with the (also-present) header-count guard"
  pass "a curl transport failure fails closed even with a full header block already captured - proven distinct from the header-count guard by the message it prints"
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

test_token_never_leaks_under_xtrace() {
  local home fakebin out
  home="$TMP_ROOT/xtrace"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN='xtrace-canary-token-value' FAKE_HEADERS_FIXTURE="$FULL_FIXTURE" bash -x "$SCRIPT" 2>&1)
  assert_no_grep "xtrace-canary-token-value" <(printf '%s' "$out") "the token must never appear anywhere in a bash -x trace of this script"
  pass "the token never leaks through a bash -x trace of this script"
}

# make_slow_fake_curl <dir>: like make_fake_curl, but writes the response
# headers immediately and then sleeps a few seconds before exiting - long
# enough for a case to signal the wrapping script mid-call.
make_slow_fake_curl() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
dfile=""
while [ $# -gt 0 ]; do
  case "$1" in
    -D) dfile=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$dfile" ] && printf 'HTTP/2 200 \r\nanthropic-ratelimit-unified-status: allowed\r\n' > "$dfile"
sleep 5
exit 0
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

test_sigterm_mid_call_cleans_up_exits_143_and_does_not_leak_under_xtrace() {
  local home fakebin tmpdir out_file pid rc token_hits
  home="$TMP_ROOT/sigterm"; mkdir -p "$home"
  fakebin=$(make_slow_fake_curl "$home")
  tmpdir="$home/tmp"; mkdir -p "$tmpdir"
  out_file="$home/out.txt"
  TMPDIR="$tmpdir" PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN='sigterm-canary-token-value' \
    bash -x "$SCRIPT" > "$out_file" 2>&1 &
  pid=$!
  sleep 1
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  rc=$?
  expect_code 143 "$rc" "a SIGTERM delivered mid-call must exit 143, proving the HUP/INT/TERM traps are real and not merely declared"
  token_hits=$(grep -c "sigterm-canary-token-value" "$out_file" 2>/dev/null) || token_hits=0
  [ "$token_hits" = "0" ] || fail "the token leaked into the bash -x trace during signal handling (the cleanup function's own 'set +o xtrace' matters here, not only the top-level one)"
  [ -z "$(find "$tmpdir" -type f 2>/dev/null)" ] || fail "a temp file survived a SIGTERM mid-call: $(find "$tmpdir" -type f)"
  pass "SIGTERM delivered mid-call is caught by a real trap (exit 143), cleans up every temp file, and never leaks the token even under bash -x"
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
  pass "no temp file (auth header, body, response, headers, curl stderr) survives a normal run"
}

test_request_body_is_exactly_the_documented_max_tokens_1_shape() {
  local home fakebin bodylog body
  home="$TMP_ROOT/body-shape"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  bodylog="$home/body.log"
  PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token FAKE_CURL_BODY_LOG="$bodylog" FAKE_HEADERS_FIXTURE="$FULL_FIXTURE" "$SCRIPT" >/dev/null
  assert_present "$bodylog" "the request body must have been sent"
  body=$(cat "$bodylog")
  assert_contains "$body" '"max_tokens":1,' "the documented ~9-token cost bound depends on max_tokens being exactly 1 (anchored with the trailing comma - an unanchored match here would also pass for 16384)"
  assert_contains "$body" '"model":"claude-haiku-4-5-20251001"' "the default model actually reaches the request body"
  [ "${#body}" -le 200 ] || fail "the request body is ${#body} bytes, far beyond the documented ~9-token shape (max_tokens bounds output only - AA5); the input side (the prompt) must stay bounded too"
  pass "the request body sent to curl is the documented max_tokens=1 shape on the default model, and its total size is bounded (not just max_tokens)"
}

test_curl_invocation_safety_properties() {
  local home fakebin log argv
  home="$TMP_ROOT/curl-safety"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token FAKE_CURL_LOG="$log" FAKE_HEADERS_FIXTURE="$FULL_FIXTURE" "$SCRIPT" >/dev/null
  assert_present "$log" "the fake curl must have been invoked"
  argv=$(cat "$log")
  assert_contains "$argv" "https://api.anthropic.com/v1/messages" "the exact documented endpoint must be used"
  assert_contains "$argv" " -X POST " "the request must be a POST, not e.g. a GET (space-anchored: an unanchored match would also pass a hypothetical -X POSTx)"
  assert_contains "$argv" "content-type: application/json" "the content-type header must be present"
  assert_contains "$argv" "anthropic-version: 2023-06-01" "the anthropic-version header must be present"
  assert_contains "$argv" "anthropic-beta: oauth-2025-04-20" "the anthropic-beta header must be present - sent deliberately, though a live call with it removed returns an identical header set on this account, so it is not proven required (ADV-7)"
  assert_contains "$argv" " -A fm-claude-quota/1 " "the identifying User-Agent must actually reach curl"
  assert_contains "$argv" " -w %{http_code}" "curl's own -w format must actually be requested, or HTTP_CODE would be empty and the numeric guard would fire on every call"
  assert_contains "$argv" " -m 10 " "the default timeout must actually be passed to curl as -m (space-anchored on both sides: an unanchored '-m 10' would also pass a mutant sending -m 100)"
  assert_not_contains "$argv" " -L " "curl must never follow redirects via the short flag"
  assert_not_contains "$argv" "--location" "curl must never follow redirects via the long flag either (ADV-1: the short-flag check alone does not catch this spelling)"
  pass "the curl invocation has every documented safety property: exact endpoint, POST, required headers, User-Agent, the http_code format, a real timeout bound, and no redirect-following under either spelling"
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

test_help_dash_h_alias_works() {
  local out rc
  out=$(env -u CLAUDE_CODE_OAUTH_TOKEN "$SCRIPT" -h 2>&1)
  rc=$?
  expect_code 0 "$rc" "-h must work the same as --help"
  assert_contains "$out" "Usage:" "help text names its usage"
  pass "-h works as an alias for --help"
}

test_unknown_flag_is_rejected() {
  local home fakebin log out rc
  home="$TMP_ROOT/unknown-flag"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  # This guard is NOT backstopped by set -u the way the --model/--timeout
  # missing-value guards are (ADV-8): a typo'd flag with no dedicated test
  # would silently probe with every default and exit 0.
  out=$(PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token FAKE_CURL_LOG="$log" "$SCRIPT" --modl claude-x 2>&1)
  rc=$?
  expect_code 2 "$rc" "an unrecognised flag must be rejected, not silently probe with defaults"
  assert_contains "$out" "unrecognised argument" "usage error names the problem"
  assert_absent "$log" "an unrecognised flag must never reach curl"
  pass "an unrecognised flag is rejected before any network call"
}

test_help_fails_loudly_when_usage_text_is_genuinely_unreadable() {
  local home stripped out rc
  home="$TMP_ROOT/help-unreadable"; mkdir -p "$home"
  stripped="$home/stripped-copy.sh"
  # A copy of the real script with every comment line removed (the shebang
  # kept) still executes identically otherwise, but its own usage-extracting
  # awk now opens the file fine and reads zero matching lines - the exact
  # "awk succeeds, output is empty" shape ADV-3 demonstrated survives a naive
  # `fm_claude_quota_usage; exit 0` and must now be caught by name.
  sed -n '1p; /^#/!p' "$SCRIPT" > "$stripped"
  chmod +x "$stripped"
  out=$(env -u CLAUDE_CODE_OAUTH_TOKEN "$stripped" --help 2>&1)
  rc=$?
  expect_code 1 "$rc" "empty (not merely unopenable) usage text must fail loudly, not silently exit 0 with zero bytes of output (ADV-3)"
  assert_contains "$out" "could not read this script" "the failure names what happened rather than exiting silently"
  pass "--help fails loudly with a clear message when its own usage text opens fine but reads as empty"
}

test_help_works_when_invoked_through_a_symlink_under_a_different_name() {
  local home link out rc
  home="$TMP_ROOT/help-symlink"; mkdir -p "$home"
  link="$home/claude-quota"
  ln -s "$SCRIPT" "$link"
  out=$(env -u CLAUDE_CODE_OAUTH_TOKEN "$link" --help 2>&1)
  rc=$?
  expect_code 0 "$rc" "--help must work when reached through a symlink under a different name (AA1 regression case)"
  assert_contains "$out" "Usage:" "help text is real, not the swallowed awk failure the AA1 regression produced"
  pass "--help works when this script is invoked through a symlink under a different name"
}

test_help_works_when_invoked_as_a_renamed_copy() {
  local home copy out rc
  home="$TMP_ROOT/help-rename"; mkdir -p "$home"
  copy="$home/quota-probe.sh"
  cp "$SCRIPT" "$copy"
  chmod +x "$copy"
  out=$(env -u CLAUDE_CODE_OAUTH_TOKEN "$copy" --help 2>&1)
  rc=$?
  expect_code 0 "$rc" "--help must work when invoked as a renamed copy (AA1 regression case)"
  assert_contains "$out" "Usage:" "help text is real, not the swallowed awk failure the AA1 regression produced"
  pass "--help works when this script is invoked as a renamed copy"
}

test_no_token_fails_closed_with_no_curl_call
test_token_with_newline_fails_closed_with_no_curl_call
test_curl_missing_fails_closed
test_timeout_rejects_non_numeric_value
test_timeout_rejects_value_above_range
test_bad_timeout_is_a_usage_error
test_full_headers_parse_and_distinguish_seat_from_spend_cap
test_unrecognised_header_does_not_break_parsing_of_the_full_set
test_subset_headers_report_missing_meters_as_unknown_not_zero
test_no_ratelimit_headers_at_all_is_a_hard_failure
test_non_2xx_without_headers_fails_closed
test_non_2xx_with_full_headers_is_parsed_not_discarded
test_headers_present_but_every_value_malformed_fails_closed
test_valid_threshold_and_fallback_do_not_rescue_all_malformed_measurements
test_raw_fields_only_with_no_measurement_fails_closed
test_malformed_header_values_read_unknown_not_a_fabricated_reading
test_trailing_whitespace_on_a_header_value_still_parses
test_duplicate_header_last_value_wins
test_curl_returns_non_numeric_http_status_fails_closed
test_curl_transport_failure_fails_closed
test_token_never_appears_in_curl_argv
test_token_never_leaks_under_xtrace
test_sigterm_mid_call_cleans_up_exits_143_and_does_not_leak_under_xtrace
test_auth_header_file_is_mode_0600_while_curl_can_see_it
test_temp_files_are_cleaned_up_after_a_run
test_request_body_is_exactly_the_documented_max_tokens_1_shape
test_curl_invocation_safety_properties
test_model_rejects_characters_outside_the_documented_set
test_model_rejects_empty_value
test_help_does_not_require_a_token
test_help_dash_h_alias_works
test_unknown_flag_is_rejected
test_help_fails_loudly_when_usage_text_is_genuinely_unreadable
test_help_works_when_invoked_through_a_symlink_under_a_different_name
test_help_works_when_invoked_as_a_renamed_copy
