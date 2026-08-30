#!/usr/bin/env bash
# Behavior tests for fm-claude-quota.sh, the non-interactive Claude quota
# reader. The network is stubbed with a fakebin `curl` that plays back
# captured anthropic-ratelimit-unified-* header fixtures, so these stay
# hermetic: no ports, no real /v1/messages call, deterministic in CI.
#
# Every fixture here is built with real CRLF line endings and an HTTP/2-style
# status line (the live API's actual wire format - all-LF, HTTP/1.1 fixtures
# never exercised the CR-strip every emitted value depends on), and the
# case-insensitive header match is exercised both with one mixed-case name
# among lowercase ones and with an all-mixed-case block.
#
# COVERAGE, MEASURED RATHER THAN ASSERTED (2026-08-30). Four review rounds on
# this branch each claimed a sweep was complete and were each disproved by
# running the full population, so the populations below are stated with their
# denominators and the survivors are named rather than rounded away. Each entry
# is one mutation applied to a pristine copy of the script, verified to have
# actually changed the file, then measured by running this entire suite:
#
#   emitted-field/header cross-mappings   272 of 272 killed  (17 fields x 16 other headers)
#   emitted-field kind mis-mappings        34 of 34  killed  (17 fields x 2 wrong shape checks)
#   emitted key/variable cross-pairings   380 of 380 killed  (20 printf keys x 19 other variables)
#   option-parser branch mutations          7 of 7   killed
#   named guards deleted or neutered       50 of 60  killed
#
# The ten surviving guard mutations are NOT claimed as covered. Each is listed
# here with why it survives, so the next editor inherits the gap rather than a
# false assurance:
#
#   set -u                       every path it would catch has its own guard,
#                                 so no single mutation is observable.
#   export LC_ALL=C              locale-dependent; grep -i behaved identically
#                                 under tr_TR.UTF-8 on the platform tested, so
#                                 no portable case makes it observable.
#   trap HUP / INT / TERM        bash's DEFAULT disposition for each of these
#                                 exits with the same 128+signum status AND
#                                 still runs the EXIT trap, so the exit status
#                                 and the cleanup are identical with or without
#                                 the trap line. The three signal tests below
#                                 pin those observable properties, which is all
#                                 $? can show; they cannot prove the dedicated
#                                 trap fired.
#   cleanup's set +o xtrace      redundant with the first top-level one, which
#   second top-level set +o xtrace  IS killed - that is where the property lives.
#   umask 077                    superseded by mktemp's own 0600 creation and by
#                                 the unconditional chmod 600 two lines later,
#                                 which is killed.
#   HEADER_HITS / UNMAPPED_HITS  they defend against grep -c emitting
#     numeric sanitisation        non-numeric output, which cannot be produced
#                                 without replacing grep entirely - and this
#                                 script's other grep uses depend on it too.
#
# All of these are defence in depth or provably redundant; none is a behaviour
# a caller can observe. The point of listing them is that "50 of 60" is a
# checkable claim and "every guard is covered" was not.
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
  'anthropic-ratelimit-unified-reset: 1788010000' \
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

# A mapping-discrimination fixture: every one of the 17 headers this script
# maps carries a PAIRWISE-DISTINCT value, plus one unrecognised header, and it
# is served under a distinct HTTP status. Realism is deliberately not its job -
# FULL_FIXTURE keeps that role. Its job is that no two emitted fields can ever
# read the same value, so any mis-mapping of any field onto any other header is
# observable rather than hidden behind a shared literal.
#
# This exists because two review rounds fixed one collision each while leaving
# the identical collision in the field beside it: a 2026-08-30 verification
# round proved 16 of the 272 possible field/header cross-mappings survived a
# green suite, 15 of them on five_hour_reset alone, which had no assertion on
# its actual value anywhere. Pinning all 20 emitted values against distinct
# sentinels in one place closes the CLASS, not an instance of it.
#
# The raw fields carry deliberately non-numeric sentinels, so a mutation that
# also changed a raw field's SHAPE-CHECK kind (raw -> utilization/reset) turns
# the sentinel into "unknown" and is caught by the same assertions.
DISTINCT_FIXTURE="$TMP_ROOT/distinct-values.txt"
crlf \
  'HTTP/2 203 ' \
  'anthropic-ratelimit-unified-status: sentinel-unified-status' \
  'anthropic-ratelimit-unified-reset: 1788000001' \
  'anthropic-ratelimit-unified-5h-status: sentinel-5h-status' \
  'anthropic-ratelimit-unified-5h-reset: 1788000002' \
  'anthropic-ratelimit-unified-5h-utilization: 0.101' \
  'anthropic-ratelimit-unified-7d-status: sentinel-7d-status' \
  'anthropic-ratelimit-unified-7d-reset: 1788000003' \
  'anthropic-ratelimit-unified-7d-utilization: 0.202' \
  'anthropic-ratelimit-unified-7d-surpassed-threshold: 0.303' \
  'anthropic-ratelimit-unified-overage-status: sentinel-overage-status' \
  'anthropic-ratelimit-unified-overage-reset: 1788000004' \
  'anthropic-ratelimit-unified-overage-utilization: 0.404' \
  'anthropic-ratelimit-unified-overage-surpassed-threshold: 0.505' \
  'anthropic-ratelimit-unified-overage-disabled-reason: sentinel-disabled-reason' \
  'anthropic-ratelimit-unified-representative-claim: sentinel-representative-claim' \
  'anthropic-ratelimit-unified-upgrade-paths: sentinel-upgrade-paths' \
  'anthropic-ratelimit-unified-fallback-percentage: 0.606' \
  'anthropic-ratelimit-unified-mapping-sentinel: 0.707' \
  > "$DISTINCT_FIXTURE"

# Every numeric-kind field malformed EXCEPT 5h-utilization, which stays valid
# so the run still exits 0 with a usable measurement and the individual
# degradations stay observable. This pins the SHAPE CHECK on each numeric field
# individually: a mutation changing any field's kind argument would stop that
# field's own check from running.
#
# The *_reset values here are deliberately chosen to be UTILIZATION-valid but
# RESET-invalid (epoch 0, and a decimal): the reset check ^[1-9][0-9]*$ is
# strictly stronger than the utilization check ^[0-9]+([.][0-9]+)?$, so plain
# non-numeric garbage cannot tell the two apart. A 2026-08-30 sweep of all 34
# kind mis-mappings found exactly 3 survivors, all of them reset -> utilization,
# for precisely that reason - a loosened reset field would then have reported
# "resets at epoch 0" as a real reading.
MALFORMED_EACH_FIXTURE="$TMP_ROOT/malformed-each.txt"
crlf \
  'HTTP/2 200 ' \
  'anthropic-ratelimit-unified-status: allowed' \
  'anthropic-ratelimit-unified-reset: 0' \
  'anthropic-ratelimit-unified-5h-reset: 0' \
  'anthropic-ratelimit-unified-5h-utilization: 0.42' \
  'anthropic-ratelimit-unified-7d-reset: 1788098400.5' \
  'anthropic-ratelimit-unified-7d-utilization: bad-7d-util' \
  'anthropic-ratelimit-unified-7d-surpassed-threshold: bad-7d-threshold' \
  'anthropic-ratelimit-unified-overage-reset: 0' \
  'anthropic-ratelimit-unified-overage-utilization: bad-overage-util' \
  'anthropic-ratelimit-unified-overage-surpassed-threshold: bad-overage-threshold' \
  'anthropic-ratelimit-unified-fallback-percentage: bad-fallback' \
  > "$MALFORMED_EACH_FIXTURE"

# Every unified header mixed-case, including the unrecognised one, and that
# unrecognised one carrying a character outside the emitted charset. The live
# wire lowercases every header name, but a proxy or intermediary need not.
# Three separate constructs survived a green suite before this fixture existed
# (2026-08-30 guard sweep): the header-COUNT grep's -i (the previous fixtures
# always had at least one all-lowercase unified header, so the count stayed
# nonzero even case-sensitively), the unmapped-name lowercasing, and the
# unmapped-name charset filter.
MIXED_CASE_FIXTURE="$TMP_ROOT/mixed-case.txt"
crlf \
  'HTTP/2 200 ' \
  'Anthropic-RateLimit-Unified-Status: allowed' \
  'Anthropic-RateLimit-Unified-5H-Reset: 1788020400' \
  'Anthropic-RateLimit-Unified-5H-Utilization: 0.55' \
  'Anthropic-RateLimit-Unified-Weird+Name: 1' \
  > "$MIXED_CASE_FIXTURE"

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
  assert_contains "$out" "CLAUDE_CODE_OAUTH_TOKEN is not set" "the dedicated no-token guard must be what fired: set -u also aborts here with the same exit status, so only the message distinguishes them"
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
  assert_kv_line "$out" "five_hour_status=allowed" "the 5h window's own status (BF-2, 2026-08-30 verification round: this field had no assertion anywhere in the suite, so mis-mapping it to unified_status went unnoticed)"
  assert_kv_line "$out" "five_hour_utilization=0.13" "5h window"
  assert_kv_line "$out" "seven_day_status=allowed_warning" "the 7d window's own status (found unasserted-when-present during the exhaustive per-field sweep, 2026-08-30 verification round: only its absent->unknown case had a test)"
  assert_kv_line "$out" "seven_day_utilization=0.94" "seat/weekly window (7d)"
  assert_kv_line "$out" "seven_day_surpassed_threshold=0.75" "seat threshold"
  assert_kv_line "$out" "overage_reset=1788220800" "the spend cap's own reset (BF-2: also had no assertion anywhere, though FULL_FIXTURE always carried a distinct value for it)"
  assert_kv_line "$out" "overage_utilization=1.05" "spend cap (overage), distinct from seven_day_utilization"
  assert_kv_line "$out" "overage_surpassed_threshold=1.0" "spend cap threshold - the other half of the seat/spend-cap pair (ADV-2): the utilization conflation alone was pinned, but not this one, so a mapping mistake between the two thresholds went unnoticed"
  assert_kv_line "$out" "overage_disabled_reason=org_spend_cap_reached" "spend cap reason"
  assert_kv_line "$out" "representative_claim=seven_day" "which window unified_status is keyed to (ADV-2: previously unpinned, so a mis-mapping to another field would not have been noticed)"
  assert_not_kv_line "$out" "overage_utilization=0.94" "overage must never be conflated with the seat window's value"
  assert_not_kv_line "$out" "overage_surpassed_threshold=0.75" "the spend-cap threshold must never be conflated with the seat threshold's value (ADV-2)"
  assert_not_kv_line "$out" "overage_reset=1788098400" "the spend-cap reset must never be conflated with the seat reset's value (BF-2)"
  assert_kv_line "$out" "unmapped_unified_headers=0" "this fixture carries only headers the script maps, so the unmapped count is zero"
  assert_kv_line "$out" "unmapped_unified_header_names=none" "and the names field reads the literal \"none\" rather than an empty value - nothing pinned this default before the 2026-08-30 guard sweep, so deleting it survived a green suite"
  pass "full header set parses (mixed-case header name, real CRLF/HTTP2 wire format), keeping the seat window and spend cap distinct on status, utilization, threshold and reset"
}

# Every one of the 20 values this script emits, asserted against a fixture in
# which no two headers share a value. This is the assertion that makes the
# field/header mapping observable as a whole rather than field by field: with
# pairwise-distinct sentinels, ANY field reading ANY other field's header
# produces a value this test names and rejects.
#
# Enumerated denominator (2026-08-30): 20 emitted keys, 17 of them mapped
# directly from a header, 3 derived (probe_http_status, unmapped_unified_headers,
# unmapped_unified_header_names). Before this test, 19 of the 20 had a positive
# value assertion somewhere and five_hour_reset had none at all; separately, two
# fields were unfalsifiable anyway because the fixtures gave their header and
# another header the same literal.
test_every_emitted_field_reads_its_own_header_and_no_other() {
  local home fakebin out rc
  home="$TMP_ROOT/distinct"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token FAKE_HTTP_CODE=203 FAKE_HEADERS_FIXTURE="$DISTINCT_FIXTURE" "$SCRIPT")
  rc=$?
  expect_code 0 "$rc" "the distinct-value fixture is a complete, valid reading"
  # All 17 header-mapped fields.
  assert_kv_line "$out" "unified_status=sentinel-unified-status" "unified_status must read the top-level status header and nothing else"
  assert_kv_line "$out" "unified_reset=1788000001" "unified_reset must read the top-level reset header and nothing else"
  assert_kv_line "$out" "five_hour_status=sentinel-5h-status" "five_hour_status must read the 5h status header and nothing else"
  assert_kv_line "$out" "five_hour_reset=1788000002" "five_hour_reset must read the 5h reset header and nothing else - this field had no assertion on its actual value anywhere in the suite, so 15 of its 16 possible mis-mappings survived a green suite, and on the live wire the 5h and overage resets were 29 hours apart"
  assert_kv_line "$out" "five_hour_utilization=0.101" "five_hour_utilization must read the 5h utilization header and nothing else"
  assert_kv_line "$out" "seven_day_status=sentinel-7d-status" "seven_day_status must read the 7d status header and nothing else"
  assert_kv_line "$out" "seven_day_reset=1788000003" "seven_day_reset must read the 7d reset header and nothing else"
  assert_kv_line "$out" "seven_day_utilization=0.202" "seven_day_utilization must read the 7d utilization header - the SEAT meter"
  assert_kv_line "$out" "seven_day_surpassed_threshold=0.303" "seven_day_surpassed_threshold must read the 7d threshold header and nothing else"
  assert_kv_line "$out" "overage_status=sentinel-overage-status" "overage_status must read the overage status header and nothing else"
  assert_kv_line "$out" "overage_reset=1788000004" "overage_reset must read the overage reset header and nothing else"
  assert_kv_line "$out" "overage_utilization=0.404" "overage_utilization must read the overage utilization header - the SPEND CAP, never the seat meter"
  assert_kv_line "$out" "overage_surpassed_threshold=0.505" "overage_surpassed_threshold must read the overage threshold header and nothing else"
  assert_kv_line "$out" "overage_disabled_reason=sentinel-disabled-reason" "overage_disabled_reason must read the overage disabled-reason header and nothing else"
  assert_kv_line "$out" "representative_claim=sentinel-representative-claim" "representative_claim must read the representative-claim header and nothing else"
  assert_kv_line "$out" "upgrade_paths=sentinel-upgrade-paths" "upgrade_paths must read the upgrade-paths header and nothing else"
  assert_kv_line "$out" "fallback_percentage=0.606" "fallback_percentage must read the fallback-percentage header and nothing else"
  # The 3 derived fields, pinned in the same reading.
  assert_kv_line "$out" "probe_http_status=203" "probe_http_status must carry curl's own reported status, distinct here from every header value"
  assert_kv_line "$out" "unmapped_unified_headers=1" "the one unrecognised header in this fixture is counted"
  assert_kv_line "$out" "unmapped_unified_header_names=mapping-sentinel" "and named"
  pass "all 20 emitted fields read their own header and no other, against a fixture where no two headers share a value"
}

# The shape check is applied per field, not just somewhere. Each numeric field
# gets its own malformed value here, so a mutation changing any one field's
# kind argument from utilization/reset to raw would pass that garbage through
# instead of reading "unknown".
test_each_numeric_field_applies_its_own_shape_check() {
  local home fakebin out rc
  home="$TMP_ROOT/malformed-each"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token FAKE_HEADERS_FIXTURE="$MALFORMED_EACH_FIXTURE" "$SCRIPT")
  rc=$?
  expect_code 0 "$rc" "one valid measurement (5h-utilization) keeps this a usable reading, so the individual degradations are observable"
  assert_kv_line "$out" "five_hour_utilization=0.42" "the one validly-shaped measurement still parses"
  assert_kv_line "$out" "unified_reset=unknown" "epoch 0 is not a valid reset; it must read unknown even though it would pass the weaker utilization check"
  assert_not_kv_line "$out" "unified_reset=0" "a reset of epoch 0 must never be emitted as a real reading"
  assert_kv_line "$out" "five_hour_reset=unknown" "epoch 0 is not a valid 5h reset either"
  assert_not_kv_line "$out" "five_hour_reset=0" "a reset of epoch 0 must never be emitted as a real reading"
  assert_kv_line "$out" "seven_day_reset=unknown" "a decimal is not a valid epoch second; it must read unknown even though it would pass the weaker utilization check"
  assert_not_kv_line "$out" "seven_day_reset=1788098400.5" "a fractional epoch must never be emitted as a real reading"
  assert_kv_line "$out" "seven_day_utilization=unknown" "a malformed 7d utilization reads unknown"
  assert_not_kv_line "$out" "seven_day_utilization=bad-7d-util" "and never passes the garbage through"
  assert_kv_line "$out" "seven_day_surpassed_threshold=unknown" "a malformed 7d threshold reads unknown"
  assert_not_kv_line "$out" "seven_day_surpassed_threshold=bad-7d-threshold" "and never passes the garbage through"
  assert_kv_line "$out" "overage_reset=unknown" "epoch 0 is not a valid overage reset either"
  assert_not_kv_line "$out" "overage_reset=0" "a reset of epoch 0 must never be emitted as a real reading"
  assert_kv_line "$out" "overage_utilization=unknown" "a malformed overage utilization reads unknown"
  assert_not_kv_line "$out" "overage_utilization=bad-overage-util" "and never passes the garbage through"
  assert_kv_line "$out" "overage_surpassed_threshold=unknown" "a malformed overage threshold reads unknown"
  assert_not_kv_line "$out" "overage_surpassed_threshold=bad-overage-threshold" "and never passes the garbage through"
  assert_kv_line "$out" "fallback_percentage=unknown" "a malformed fallback percentage reads unknown"
  assert_not_kv_line "$out" "fallback_percentage=bad-fallback" "and never passes the garbage through"
  pass "every numeric field applies its own shape check individually, degrading to unknown rather than passing malformed data through"
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
  assert_kv_line "$out" "unified_reset=1788010000" "a header this script did not originally name (AA4) is now parsed explicitly. Deliberately a value distinct from every other *_reset in this fixture (BF-2, 2026-08-30 verification round): the original fixture gave unified_reset and seven_day_reset the identical value 1788098400, so a mutant that mis-mapped unified_reset onto anthropic-ratelimit-unified-7d-reset survived undetected - the live wire showed these two fields ~6.8 days apart on the account this script was tested against"
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

# test_sigterm_mid_call_observable_behavior_is_safe: what this test proves,
# stated exactly, after a 2026-08-30 verification round found the previous
# name/message claimed more (BF-1). On this bash, an UNTRAPPED fatal signal
# still runs the EXIT trap before the process dies, and `wait` reports the
# same 128+signum status (143 for TERM) that an explicit `trap '...; exit
# 143' TERM` would also produce - the two are indistinguishable through $?,
# which is the only thing a portable test can read here. So this test does
# NOT prove the dedicated TERM/HUP/INT trap lines specifically fired rather
# than bash's own default disposition (proving that would need something
# lower-level than $?, e.g. WIFSIGNALED, which bash does not expose). What
# it DOES prove, and what its name says: a SIGTERM delivered mid-call always
# results in exit 143, leaves no temp file behind, and never leaks the token
# into a live bash -x trace - real, verified, observable properties of the
# script's behavior under a mid-call kill, regardless of which mechanism
# produces them.
test_sigterm_mid_call_observable_behavior_is_safe() {
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
  expect_code 143 "$rc" "a SIGTERM delivered mid-call must exit 143 (this pins the observable exit status only - see the function comment above on what it cannot distinguish)"
  token_hits=$(grep -c "sigterm-canary-token-value" "$out_file" 2>/dev/null) || token_hits=0
  [ "$token_hits" = "0" ] || fail "the token leaked into the bash -x trace during signal handling"
  [ -z "$(find "$tmpdir" -type f 2>/dev/null)" ] || fail "a temp file survived a SIGTERM mid-call: $(find "$tmpdir" -type f)"
  pass "a SIGTERM delivered mid-call exits 143, leaves no temp file, and never leaks the token into a bash -x trace"
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
  local home fakebin log argv last_token first_token
  home="$TMP_ROOT/curl-safety"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token FAKE_CURL_LOG="$log" FAKE_HEADERS_FIXTURE="$FULL_FIXTURE" "$SCRIPT" >/dev/null
  assert_present "$log" "the fake curl must have been invoked"
  argv=$(cat "$log")
  # The endpoint is always the LAST argv token in the real invocation, so an
  # exact match on that last token (rather than assert_contains, which would
  # also pass for the base URL with a query string appended - found during
  # the 2026-08-30 exhaustive assertion sweep) is what actually pins it.
  first_token=$(printf '%s' "${argv#argv=}" | awk '{print $1}')
  [ "$first_token" = "-sS" ] || fail "curl must be invoked with -sS (silent, but still reporting errors) as its first flag, got: $first_token"
  last_token=$(printf '%s' "$argv" | awk '{print $NF}')
  [ "$last_token" = "https://api.anthropic.com/v1/messages" ] || fail "the exact documented endpoint must be the final argv token, got: $last_token"
  assert_contains "$argv" " -X POST " "the request must be a POST, not e.g. a GET (space-anchored: an unanchored match would also pass a hypothetical -X POSTx)"
  assert_contains "$argv" "content-type: application/json " "the content-type header must be present (trailing-anchored: the unanchored form also passed for application/jsonl or a charset-appended variant)"
  assert_contains "$argv" "anthropic-version: 2023-06-01 " "the anthropic-version header must be present (trailing-anchored: the unanchored form also passed for a mutant sending 2023-06-011, i.e. a different API version)"
  assert_contains "$argv" "anthropic-beta: oauth-2025-04-20 " "the anthropic-beta header must be present (trailing-anchored for the same reason as the two above) - sent deliberately, though a live call with it removed returns an identical header set on this account, so it is not proven required (ADV-7)"
  assert_contains "$argv" " -A fm-claude-quota/1 " "the identifying User-Agent must actually reach curl"
  assert_contains "$argv" " -w %{http_code} " "curl's own -w format must actually be requested exactly, or HTTP_CODE would carry extra data appended to it (space-anchored on both sides - found unanchored on the trailing side during the 2026-08-30 sweep, where extending the format string to %{http_code}%{time_total} survived)"
  assert_contains "$argv" " -m 10 " "the default timeout must actually be passed to curl as -m (space-anchored on both sides: an unanchored '-m 10' would also pass a mutant sending -m 100)"
  # BF-3 (2026-08-30 verification round): substring-matching " -L " and
  # "--location" only pins two specific spellings/positions of the flag -
  # `curl -sSL` and a trailing `-L` after the URL both survived a green
  # suite under the old checks. --max-redirs 0 pins the actual PROPERTY
  # (curl will not act on a redirect) regardless of how -L is spelled or
  # where it appears, so it is the authoritative assertion here; the two
  # substring checks are kept only as a cheap, redundant early signal.
  assert_contains "$argv" " --max-redirs 0 " "curl must be given --max-redirs 0, which is what actually prevents the bearer token from being replayed to a redirect target regardless of -L's spelling or position (space-anchored on both sides: the unanchored form this assertion was first written with also passed for --max-redirs 07, which follows redirects and replays the bearer token - demonstrated end to end against a local redirect server during the 2026-08-30 verification round, with the suite green)"
  assert_not_contains "$argv" " -L " "curl must never follow redirects via the short flag (redundant with --max-redirs 0 above)"
  assert_not_contains "$argv" "--location" "curl must never follow redirects via the long flag either (redundant with --max-redirs 0 above)"
  # Two credential-exposure properties that no assertion pinned before the
  # 2026-08-30 verification round: adding either flag survived a green suite.
  # Neither is a defect in the shipped script; both are cheap to pin while the
  # argv block is being anchored anyway.
  assert_not_contains "$argv" "--insecure" "curl must never be told to skip TLS verification - the bearer token would then be exposed to any interception on the path"
  assert_not_contains "$argv" " -k " "curl must never skip TLS verification via the short flag either"
  assert_not_contains "$argv" " -x " "curl must never be pointed at a proxy - the bearer token would then be handed to a third party"
  assert_not_contains "$argv" "--proxy" "curl must never be pointed at a proxy via the long flag either"
  pass "the curl invocation has every documented safety property: exact endpoint, POST, required headers, User-Agent, the http_code format, a real timeout bound, and --max-redirs 0 (which pins the no-redirect-following property regardless of -L's spelling or position)"
}

# The --model=VALUE / --timeout=VALUE spellings are separate case branches from
# the space-separated ones, and had no test at all until the 2026-08-30
# coverage pass: deleting either branch made that spelling fall through to the
# unrecognised-argument guard, with a green suite. This also pins that a
# NON-DEFAULT model and timeout actually reach curl - every other assertion in
# this suite exercises only the defaults, so a mutation ignoring the parsed
# value and always sending the default survived too.
# make_failing_mktemp <dir>: drops a `mktemp` shim into the same fakebin as the
# fake curl. It counts invocations in a file and, on the call named by
# FAKE_MKTEMP_FAIL_ON, either exits nonzero (simulating an exhausted or
# unwritable TMPDIR) or - when FAKE_MKTEMP_DIR_ON names it - creates a
# DIRECTORY where the script expects a file, which is the cheapest way to make
# the subsequent write fail while mktemp and chmod both still succeed. Every
# other call delegates to the real mktemp.
#
# This exists because seven of the script's guards (four mktemp failures, the
# chmod failure, the auth-file write failure, and the auth mktemp failure)
# fire only on a filesystem error, so nothing exercised them: all seven
# survived deletion against a green suite in the 2026-08-30 guard sweep.
make_failing_mktemp() {
  local dir=$1 fakebin real
  fakebin=$(fm_fakebin "$dir")
  real=$(command -v mktemp)
  cat > "$fakebin/mktemp" <<SH
#!/usr/bin/env bash
n=\$(cat "\$FAKE_MKTEMP_COUNT" 2>/dev/null || echo 0)
n=\$((n + 1))
printf '%s' "\$n" > "\$FAKE_MKTEMP_COUNT"
if [ "\$n" = "\${FAKE_MKTEMP_FAIL_ON:-}" ]; then
  printf 'mktemp: simulated failure\n' >&2
  exit 1
fi
if [ "\$n" = "\${FAKE_MKTEMP_DIR_ON:-}" ]; then
  d=\$($real -d "\$@") || exit 1
  printf '%s\n' "\$d"
  exit 0
fi
exec $real "\$@"
SH
  chmod +x "$fakebin/mktemp"
  printf '%s\n' "$fakebin"
}

# Each of the five mktemp calls, in the order the script makes them, failed in
# turn. Each must fail closed with its OWN message: they backstop each other
# (a failed auth mktemp also trips the chmod guard), so only the message
# distinguishes which guard actually fired.
test_each_temp_file_creation_failure_fails_closed_with_its_own_message() {
  local home fakebin countfile out rc n want
  home="$TMP_ROOT/mktemp-fail"; mkdir -p "$home"
  make_fake_curl "$home" >/dev/null
  fakebin=$(make_failing_mktemp "$home")
  countfile="$home/mktemp.count"
  n=0
  for want in \
    "could not create a temp file for the auth header" \
    "could not create a temp file for the request body" \
    "could not create a temp file for response headers" \
    "could not create a temp file for the response body" \
    "could not create a temp file for curl diagnostics"; do
    n=$((n + 1))
    rm -f "$countfile"
    out=$(PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token \
      FAKE_MKTEMP_COUNT="$countfile" FAKE_MKTEMP_FAIL_ON="$n" \
      FAKE_HEADERS_FIXTURE="$FULL_FIXTURE" "$SCRIPT" 2>&1)
    rc=$?
    expect_code 1 "$rc" "a failure creating temp file $n must fail closed"
    assert_contains "$out" "$want" "temp file $n's own guard must be the one that fired"
    assert_not_contains "$out" "=" "a temp-file failure must never print any key=value line"
  done
  pass "each of the five temp-file creations failing in turn fails closed with that guard's own message"
}

test_auth_file_permission_failure_fails_closed() {
  local home fakebin out rc
  home="$TMP_ROOT/chmod-fail"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  cat > "$fakebin/chmod" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/chmod"
  out=$(PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token FAKE_HEADERS_FIXTURE="$FULL_FIXTURE" "$SCRIPT" 2>&1)
  rc=$?
  expect_code 1 "$rc" "failing to restrict the auth file's permissions must fail closed rather than proceed with a world-readable token file"
  assert_contains "$out" "could not restrict permissions on the auth header temp file" "the permission guard's own message must be what fired"
  assert_not_contains "$out" "=" "this failure must never print any key=value line"
  pass "a chmod failure on the auth header temp file fails closed rather than proceeding with an unrestricted token file"
}

test_auth_file_write_failure_fails_closed() {
  local home fakebin countfile out rc
  home="$TMP_ROOT/auth-write-fail"; mkdir -p "$home"
  make_fake_curl "$home" >/dev/null
  fakebin=$(make_failing_mktemp "$home")
  countfile="$home/mktemp.count"
  # mktemp returns a DIRECTORY for the auth file: mktemp and chmod both
  # succeed, and only the write itself fails.
  out=$(PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token \
    FAKE_MKTEMP_COUNT="$countfile" FAKE_MKTEMP_DIR_ON=1 \
    FAKE_HEADERS_FIXTURE="$FULL_FIXTURE" "$SCRIPT" 2>&1)
  rc=$?
  expect_code 1 "$rc" "failing to write the auth header file must fail closed rather than call the API with no Authorization header"
  assert_contains "$out" "could not write the auth header temp file" "the write guard's own message must be what fired"
  assert_not_contains "$out" "=" "this failure must never print any key=value line"
  pass "a failure writing the auth header temp file fails closed rather than probing unauthenticated"
}

test_every_header_name_mixed_case_still_parses_and_normalises_unmapped_names() {
  local home fakebin out rc
  home="$TMP_ROOT/mixed-case"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token FAKE_HEADERS_FIXTURE="$MIXED_CASE_FIXTURE" "$SCRIPT")
  rc=$?
  expect_code 0 "$rc" "a response whose unified headers are ALL mixed-case must still be recognised as carrying meters at all - the header-count grep is case-insensitive"
  assert_kv_line "$out" "five_hour_utilization=0.55" "a mixed-case header name still resolves to its field"
  assert_kv_line "$out" "five_hour_reset=1788020400" "and so does the reset beside it"
  assert_kv_line "$out" "unmapped_unified_headers=1" "the mixed-case unrecognised header is still counted"
  assert_kv_line "$out" "unmapped_unified_header_names=weirdname" "an unmapped header name is lowercased AND filtered to the emitted charset: Weird+Name -> weirdname. Without the lowercasing it would read eirdame (the charset filter strips capitals); without the charset filter it would read weird+name"
  pass "an all-mixed-case header block parses, and an unmapped header name is lowercased and charset-filtered before being emitted"
}

# HUP and INT, the two signal traps nothing exercised before the 2026-08-30
# guard sweep - deleting either survived a green suite. As with the SIGTERM
# case above, this pins the OBSERVABLE behaviour (exit status, no temp file
# left behind) and deliberately does not claim to prove the dedicated trap
# line fired rather than bash's default disposition: $? cannot tell them apart.
assert_signal_mid_call_is_clean() {
  local signal=$1 want=$2 home fakebin tmpdir pid rc
  home="$TMP_ROOT/sig-$signal"; mkdir -p "$home"
  fakebin=$(make_slow_fake_curl "$home")
  tmpdir="$home/tmp"; mkdir -p "$tmpdir"
  # Job control on: a background job started from a NON-interactive shell
  # inherits SIGINT as SIG_IGN, and bash cannot trap a signal it inherited
  # ignored - so without set -m the SIGINT case silently exits 0 having
  # ignored the signal entirely, which would make this test vacuous.
  set -m
  TMPDIR="$tmpdir" PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token \
    "$SCRIPT" >/dev/null 2>&1 &
  pid=$!
  set +m
  sleep 1
  kill -"$signal" "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  rc=$?
  expect_code "$want" "$rc" "a SIG$signal delivered mid-call must exit $want"
  [ -z "$(find "$tmpdir" -type f 2>/dev/null)" ] || fail "a temp file survived a SIG$signal mid-call: $(find "$tmpdir" -type f)"
}

test_sighup_mid_call_exits_129_and_leaves_no_temp_file() {
  assert_signal_mid_call_is_clean HUP 129
  pass "a SIGHUP delivered mid-call exits 129 and leaves no temp file behind"
}

test_sigint_mid_call_exits_130_and_leaves_no_temp_file() {
  assert_signal_mid_call_is_clean INT 130
  pass "a SIGINT delivered mid-call exits 130 and leaves no temp file behind"
}

# The two option guards that reject a flag given with no value at all. Both are
# backstopped by set -u (which aborts on the unset $2), so only the exit status
# and the guard's own message distinguish them - deleting either survived a
# green suite before the 2026-08-30 guard sweep.
test_option_with_no_value_is_a_usage_error_naming_the_option() {
  local home fakebin log out rc
  home="$TMP_ROOT/missing-value"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  out=$(PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token FAKE_CURL_LOG="$log" "$SCRIPT" --model 2>&1)
  rc=$?
  expect_code 2 "$rc" "--model with no value must be a usage error (exit 2), not a set -u abort (exit 1)"
  assert_contains "$out" "--model requires a value" "the guard's own message must name the option"
  out=$(PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token FAKE_CURL_LOG="$log" "$SCRIPT" --timeout 2>&1)
  rc=$?
  expect_code 2 "$rc" "--timeout with no value must be a usage error (exit 2), not a set -u abort (exit 1)"
  assert_contains "$out" "--timeout requires a value" "the guard's own message must name the option"
  assert_absent "$log" "neither malformed invocation may reach curl"
  pass "--model and --timeout given with no value are usage errors naming the option, not bare set -u aborts"
}

test_equals_form_options_are_parsed_and_reach_curl() {
  local home fakebin log bodylog argv body rc
  home="$TMP_ROOT/equals-form"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"; bodylog="$home/body.log"
  PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token FAKE_CURL_LOG="$log" \
    FAKE_CURL_BODY_LOG="$bodylog" FAKE_HEADERS_FIXTURE="$FULL_FIXTURE" \
    "$SCRIPT" --model=claude-probe-model-9 --timeout=25 >/dev/null
  rc=$?
  expect_code 0 "$rc" "the --opt=value spelling must be accepted, not rejected as an unrecognised argument"
  assert_present "$log" "the equals-form invocation must still reach curl"
  argv=$(cat "$log"); body=$(cat "$bodylog")
  assert_contains "$argv" " -m 25 " "a non-default --timeout=25 must reach curl as -m 25, not the default 10 (space-anchored on both sides)"
  assert_not_contains "$argv" " -m 10 " "the default timeout must not be sent when a non-default one was given"
  assert_contains "$body" '"model":"claude-probe-model-9"' "a non-default --model= must reach the request body, not the default model"
  assert_not_contains "$body" "claude-haiku-4-5-20251001" "the default model must not be sent when a non-default one was given"
  pass "the --model=/--timeout= equals spellings parse and their non-default values reach curl"
}

# The space-separated spellings, same property: a non-default value must
# actually reach curl rather than the default being sent regardless.
test_space_form_non_default_values_reach_curl() {
  local home fakebin log bodylog argv body rc
  home="$TMP_ROOT/space-form"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"; bodylog="$home/body.log"
  PATH="$fakebin:$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN=fake-token FAKE_CURL_LOG="$log" \
    FAKE_CURL_BODY_LOG="$bodylog" FAKE_HEADERS_FIXTURE="$FULL_FIXTURE" \
    "$SCRIPT" --model claude-probe-model-9 --timeout 25 >/dev/null
  rc=$?
  expect_code 0 "$rc" "the space-separated spelling must be accepted"
  argv=$(cat "$log"); body=$(cat "$bodylog")
  assert_contains "$argv" " -m 25 " "a non-default --timeout must reach curl as -m 25 (space-anchored on both sides)"
  assert_not_contains "$argv" " -m 10 " "the default timeout must not be sent when a non-default one was given"
  assert_contains "$body" '"model":"claude-probe-model-9"' "a non-default --model must reach the request body"
  assert_not_contains "$body" "claude-haiku-4-5-20251001" "the default model must not be sent when a non-default one was given"
  pass "the space-separated --model/--timeout spellings pass their non-default values through to curl"
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
test_every_emitted_field_reads_its_own_header_and_no_other
test_each_numeric_field_applies_its_own_shape_check
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
test_sigterm_mid_call_observable_behavior_is_safe
test_auth_header_file_is_mode_0600_while_curl_can_see_it
test_temp_files_are_cleaned_up_after_a_run
test_request_body_is_exactly_the_documented_max_tokens_1_shape
test_curl_invocation_safety_properties
test_every_header_name_mixed_case_still_parses_and_normalises_unmapped_names
test_each_temp_file_creation_failure_fails_closed_with_its_own_message
test_auth_file_permission_failure_fails_closed
test_auth_file_write_failure_fails_closed
test_sighup_mid_call_exits_129_and_leaves_no_temp_file
test_sigint_mid_call_exits_130_and_leaves_no_temp_file
test_option_with_no_value_is_a_usage_error_naming_the_option
test_equals_form_options_are_parsed_and_reach_curl
test_space_form_non_default_values_reach_curl
test_model_rejects_characters_outside_the_documented_set
test_model_rejects_empty_value
test_help_does_not_require_a_token
test_help_dash_h_alias_works
test_unknown_flag_is_rejected
test_help_fails_loudly_when_usage_text_is_genuinely_unreadable
test_help_works_when_invoked_through_a_symlink_under_a_different_name
test_help_works_when_invoked_as_a_renamed_copy
