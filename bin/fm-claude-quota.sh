#!/usr/bin/env bash
# fm-claude-quota.sh - read the captain's Claude subscription quota meters
# non-interactively, by making one max_tokens=1 call to /v1/messages and
# parsing the anthropic-ratelimit-unified-* response headers Claude Code
# itself relies on.
#
# Why this script exists: quota-axi covers every other provider firstmate
# routes on, but it can never cover Claude here. A token minted by
# `claude setup-token` (the same shape as the durable CLAUDE_CODE_OAUTH_TOKEN
# this script reads) is permanently scoped user:inference-only, so it cannot
# read /api/oauth/usage or any other account-state endpoint - that returns a
# 403 oauth_scope_insufficient, not a fixable auth failure. The unified
# rate-limit headers are the one channel that token can read, because they
# ride on the same inference call the token is scoped for. See
# data/claude-usage-visibility/report.md (private, 2026-08-29) for the full
# investigation and the option comparison that led here.
#
# This script only reads and reports. It does not decide anything, retry
# anything, or feed a routing path - wiring the numbers it prints into
# fm-harness.sh / quota-array-dispatch is a separate, later change.
#
# Usage:
#   fm-claude-quota.sh [--model <model>] [--timeout <seconds>]
#   fm-claude-quota.sh --help
#
# --model <model>     the model probed (default: claude-haiku-4-5-20251001,
#                      confirmed live to return HTTP 200 with the full header
#                      set). Any current Claude model works; a small/cheap one
#                      keeps the probe near its minimum cost. Restricted to
#                      [A-Za-z0-9._-] - a model id is interpolated into the
#                      request body's JSON, and that character set is the
#                      cheapest way to keep it from ever being read as
#                      anything but a literal string value, which is what
#                      keeps the documented ~9-token cost bound real.
# --timeout <seconds> bounds the whole HTTP call (curl -m), 1..60,
#                      default 10. The call can never hang past this.
#
# Authentication: CLAUDE_CODE_OAUTH_TOKEN must be set in the environment -
# the same durable token firstmate/T3 already uses for Claude, minted by
# `claude setup-token`. No new credential and no new scope are requested.
# The token is written to a mode-0600 temp file and passed to curl as
# `-H "@<file>"`, so it never appears in curl's argv (never visible to `ps`)
# and the file is removed on exit. Shell tracing (`set -x`/`bash -x`) is
# explicitly disabled by this script for the same reason: if this script is
# ever invoked or sourced under xtrace, the trace would otherwise print every
# command including the one that writes the token to that file. The token is
# never otherwise printed, logged, or included in any error message. A
# process-killed-outright (SIGKILL) exit is the one case no shell trap can
# run for, so the mode-0600 auth temp file can outlive a SIGKILL'd run in
# TMPDIR; mode 0600 keeps that exposure scoped to the same local user.
#
# Cost: one real /v1/messages call, ~9 tokens total (8 in + 1 out on Haiku).
# This is a real inference call against the seat, not a free endpoint -
# /v1/messages/count_tokens was tried and confirmed to carry none of the
# ratelimit headers, so a genuine call is unavoidable. Poll on a sane cadence
# (minutes, not seconds); this script does not rate-limit its own callers -
# that belongs with whatever later work wires this reader into a routing or
# polling path, not with the reader itself.
#
# Output: one "key=value" line per meter on stdout, only on success (exit 0).
# Split each line on the FIRST "=" only - no value here contains one today,
# but none is guaranteed not to in the future. A key whose header this
# account/plan did not return, or whose value fails its shape check below,
# prints "unknown" - never a fabricated zero and never a hard failure,
# because a different account, plan, or Anthropic rollout can return a
# different subset of the documented anthropic-ratelimit-unified-* headers,
# and a header value that arrives malformed must never be read as a real
# (and possibly falsely reassuring) reading. Every *_utilization value is
# checked against ^[0-9]+([.][0-9]+)?$ (a non-negative decimal - utilization
# can legitimately exceed 1 once a cap is overrun) and every *_reset value
# against ^[1-9][0-9]*$ (a positive integer Unix epoch second) - this is a
# SHAPE check only, not a plausibility one: a syntactically valid but absurd
# epoch (e.g. "1") still passes as a reading, because bounding "plausible"
# would need this script to trust its own clock, and Anthropic controls this
# value regardless. Either shape check failing reads "unknown" rather than
# passing through whatever arrived.
#
#   probe_http_status                    the HTTP status this reading came
#                                         from. Usually 2xx; see below for why
#                                         a non-2xx can still carry a reading.
#   unified_status                       overall verdict: allowed |
#                                         allowed_warning | rejected | unknown
#   unified_reset                        the reset time unified_status itself
#                                         is keyed to (distinct from the
#                                         per-window resets below)
#   five_hour_status five_hour_reset five_hour_utilization
#                                         the rolling 5-hour session window
#   seven_day_status seven_day_reset seven_day_utilization
#   seven_day_surpassed_threshold
#                                         the SEAT meter: the weekly,
#                                         all-models subscription window.
#                                         Distinct from overage_* below - do
#                                         not conflate the two.
#   overage_status overage_reset overage_utilization
#   overage_surpassed_threshold overage_disabled_reason
#                                         the SPEND CAP meter: credit/dollar
#                                         overage, separate from the seat
#                                         window above. overage_disabled_reason
#                                         (e.g. org_spend_cap_reached) is only
#                                         present when overage is unavailable.
#   representative_claim                 which window the top-level
#                                         unified_status is currently keyed to
#   upgrade_paths                        comma-list of paths Anthropic
#                                         currently offers this account
#   fallback_percentage                  a further utilization-shaped meter
#                                         Anthropic has been observed to add
#   unmapped_unified_headers             count of anthropic-ratelimit-unified-*
#                                         response headers that matched none
#                                         of the field names above. The header
#                                         set has been observed to change
#                                         within days (a header this script
#                                         once confirmed absent can reappear),
#                                         so a nonzero count here is a signal
#                                         that a future header set may carry
#                                         quota information this script does
#                                         not yet surface by name - it is not
#                                         itself a failure.
#
# utilization is a 0-1 fraction (0.94 = 94% used, and can exceed 1 once a
# spend cap is overrun); reset is a Unix epoch second. Neither is reformatted
# here - a caller wanting a clock time or a percentage string converts it.
#
# Failure is always closed and always explicit, on stderr, with a nonzero
# exit: no token, curl missing, the HTTP call failing or timing out, a
# response - of any HTTP status - that carries no anthropic-ratelimit-unified-*
# headers at all, or a response that carries such headers but whose values
# ALL fail their shape check (which reads identically to "this plan reports
# fewer meters" unless it is itself distinguished - see the header-count and
# parsed-count guards below). None of these print any "key=value" line - a
# caller must never mistake a failed probe for a real all-unknown reading.
#
# A response that carries these headers is parsed and emitted exactly the
# same way regardless of its HTTP status: a rate-limited or rejected call
# (429, 403) is precisely the state where the reading matters most, and
# Anthropic's own server volunteers it right alongside the rejection. Only a
# response carrying no usable meters at all - a malformed call, a wrong
# endpoint, a contract change - is treated as a probe failure rather than a
# reading. Whether a 5xx (as opposed to 4xx) carrying meters should be
# trusted the same way is an open design question for whichever later work
# wires this reader into a routing path, not settled here; a careful caller
# should gate on probe_http_status until it is.
set -u
export LC_ALL=C
set +o xtrace

# The file this script itself was invoked as - read directly, with no
# reconstruction, so --help still works when this script is reached through a
# symlink or a renamed copy (bin/fm-afk-return.sh uses this same convention).
# A previous version of this file computed a path by appending a hard-coded
# literal filename to dirname("${BASH_SOURCE[0]}"), which broke --help under
# exactly that symlink/rename case - fixed here by using BASH_SOURCE[0]
# itself, which always resolves to whatever was actually invoked.
SELF="${BASH_SOURCE[0]}"

fm_claude_quota_usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$SELF"
}

MODEL=claude-haiku-4-5-20251001
TIMEOUT=10
while [ "$#" -gt 0 ]; do
  case "$1" in
    --model)
      [ "$#" -ge 2 ] || { printf 'fm-claude-quota.sh: --model requires a value.\n' >&2; exit 2; }
      MODEL=$2
      shift 2
      ;;
    --model=*)
      MODEL=${1#*=}
      shift
      ;;
    --timeout)
      [ "$#" -ge 2 ] || { printf 'fm-claude-quota.sh: --timeout requires a value.\n' >&2; exit 2; }
      TIMEOUT=$2
      shift 2
      ;;
    --timeout=*)
      TIMEOUT=${1#*=}
      shift
      ;;
    --help|-h)
      # Exit status reflects whether the usage text was actually readable -
      # not an unconditional success - so a broken SELF path (or any other
      # reason awk fails) is reported rather than silently exiting 0.
      if fm_claude_quota_usage; then
        exit 0
      fi
      printf 'fm-claude-quota.sh: could not read this script'"'"'s own usage text from %s.\n' "$SELF" >&2
      exit 1
      ;;
    *)
      printf 'fm-claude-quota.sh: unrecognised argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

case "$TIMEOUT" in
  ''|*[!0-9]*) printf 'fm-claude-quota.sh: --timeout must be a whole number of seconds.\n' >&2; exit 2 ;;
esac
if [ "$TIMEOUT" -lt 1 ] || [ "$TIMEOUT" -gt 60 ]; then
  printf 'fm-claude-quota.sh: --timeout must be between 1 and 60, got %s.\n' "$TIMEOUT" >&2
  exit 2
fi
case "$MODEL" in
  ''|*[!A-Za-z0-9._-]*)
    printf 'fm-claude-quota.sh: --model must be non-empty and contain only letters, digits, "." "_" "-".\n' >&2
    exit 2
    ;;
esac

command -v curl >/dev/null 2>&1 || {
  printf 'fm-claude-quota.sh: curl is required and was not found on PATH.\n' >&2
  exit 1
}

if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  printf 'fm-claude-quota.sh: CLAUDE_CODE_OAUTH_TOKEN is not set; cannot read Claude quota without it.\n' >&2
  exit 1
fi
case "$CLAUDE_CODE_OAUTH_TOKEN" in
  *$'\n'*|*$'\r'*)
    printf 'fm-claude-quota.sh: CLAUDE_CODE_OAUTH_TOKEN contains a newline; refusing to use it.\n' >&2
    exit 1
    ;;
esac

AUTH_FILE=
BODY_FILE=
HEADERS_FILE=
RESPONSE_BODY_FILE=
CURL_STDERR_FILE=
# shellcheck disable=SC2329 # Registered by the EXIT/HUP/INT/TERM traps below.
fm_claude_quota_cleanup() {
  set +o xtrace
  [ -z "$AUTH_FILE" ] || rm -f "$AUTH_FILE"
  [ -z "$BODY_FILE" ] || rm -f "$BODY_FILE"
  [ -z "$HEADERS_FILE" ] || rm -f "$HEADERS_FILE"
  [ -z "$RESPONSE_BODY_FILE" ] || rm -f "$RESPONSE_BODY_FILE"
  [ -z "$CURL_STDERR_FILE" ] || rm -f "$CURL_STDERR_FILE"
}
trap fm_claude_quota_cleanup EXIT
trap 'fm_claude_quota_cleanup; exit 129' HUP
trap 'fm_claude_quota_cleanup; exit 130' INT
trap 'fm_claude_quota_cleanup; exit 143' TERM

set +o xtrace
AUTH_FILE=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-claude-quota-auth.XXXXXX") || {
  printf 'fm-claude-quota.sh: could not create a temp file for the auth header.\n' >&2
  exit 1
}
chmod 600 "$AUTH_FILE" 2>/dev/null || {
  printf 'fm-claude-quota.sh: could not restrict permissions on the auth header temp file.\n' >&2
  exit 1
}
printf 'Authorization: Bearer %s\n' "$CLAUDE_CODE_OAUTH_TOKEN" > "$AUTH_FILE" || {
  printf 'fm-claude-quota.sh: could not write the auth header temp file.\n' >&2
  exit 1
}

BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-claude-quota-body.XXXXXX") || {
  printf 'fm-claude-quota.sh: could not create a temp file for the request body.\n' >&2
  exit 1
}
printf '{"model":"%s","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}\n' "$MODEL" > "$BODY_FILE"

HEADERS_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-claude-quota-headers.XXXXXX") || {
  printf 'fm-claude-quota.sh: could not create a temp file for response headers.\n' >&2
  exit 1
}
RESPONSE_BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-claude-quota-resp.XXXXXX") || {
  printf 'fm-claude-quota.sh: could not create a temp file for the response body.\n' >&2
  exit 1
}
CURL_STDERR_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-claude-quota-stderr.XXXXXX") || {
  printf 'fm-claude-quota.sh: could not create a temp file for curl diagnostics.\n' >&2
  exit 1
}

HTTP_CODE=$(curl -sS -m "$TIMEOUT" \
  -D "$HEADERS_FILE" \
  -o "$RESPONSE_BODY_FILE" \
  -w '%{http_code}' \
  -A 'fm-claude-quota/1 (+firstmate)' \
  -X POST \
  -H "@$AUTH_FILE" \
  -H 'content-type: application/json' \
  -H 'anthropic-version: 2023-06-01' \
  -H 'anthropic-beta: oauth-2025-04-20' \
  --data-binary "@$BODY_FILE" \
  'https://api.anthropic.com/v1/messages' 2>"$CURL_STDERR_FILE")
CURL_RC=$?

rm -f "$AUTH_FILE" "$BODY_FILE"
AUTH_FILE=
BODY_FILE=

if [ "$CURL_RC" -ne 0 ]; then
  printf 'fm-claude-quota.sh: the probe call to /v1/messages failed (curl exit %s).\n' "$CURL_RC" >&2
  if [ -s "$CURL_STDERR_FILE" ]; then
    printf 'fm-claude-quota.sh: curl diagnostic: %s\n' "$(head -c 500 "$CURL_STDERR_FILE")" >&2
  fi
  exit 1
fi
case "$HTTP_CODE" in
  ''|*[!0-9]*)
    printf 'fm-claude-quota.sh: the probe call returned no usable HTTP status.\n' >&2
    exit 1
    ;;
esac

# fm_claude_quota_field <header-name>: the last matching header's value from
# HEADERS_FILE (deliberately the last on a duplicate - matches curl/HTTP
# semantics for a repeated header), with leading whitespace and trailing
# whitespace (RFC 9110 OWS - including a trailing CR from a CRLF response,
# since \r is itself whitespace under the C locale this script exports)
# stripped symmetrically. Grep -i so a lowercased HTTP/2 response, which
# lowercases every header name on the wire, still matches.
fm_claude_quota_field() {
  local name=$1 line
  line=$(grep -i "^${name}:" "$HEADERS_FILE" 2>/dev/null | tail -n1) || return 0
  [ -n "$line" ] || return 0
  line=${line#*:}
  line=${line#"${line%%[![:space:]]*}"}
  line=${line%"${line##*[![:space:]]}"}
  printf '%s' "$line"
}

HEADER_HITS=$(grep -ci '^anthropic-ratelimit-unified-' "$HEADERS_FILE" 2>/dev/null) || HEADER_HITS=0
case "$HEADER_HITS" in ''|*[!0-9]*) HEADER_HITS=0 ;; esac
if [ "$HEADER_HITS" -eq 0 ]; then
  printf 'fm-claude-quota.sh: the probe returned HTTP %s with no anthropic-ratelimit-unified-* headers at all; treating this as a probe failure rather than a fabricated reading.\n' "$HTTP_CODE" >&2
  if [ -s "$RESPONSE_BODY_FILE" ]; then
    printf 'fm-claude-quota.sh: response body: %s\n' "$(head -c 500 "$RESPONSE_BODY_FILE")" >&2
  fi
  exit 1
fi

# fm_claude_quota_or_unknown <header-name> <kind: raw|utilization|reset>:
# the header's value when present and, for the two numeric kinds, shaped
# correctly - "unknown" otherwise. This is the single point malformed data is
# turned into "unknown" rather than passed through, per the header comment.
fm_claude_quota_or_unknown() {
  local name=$1 kind=$2 value
  value=$(fm_claude_quota_field "$name")
  if [ -z "$value" ]; then
    printf 'unknown\n'
    return 0
  fi
  case "$kind" in
    utilization)
      [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || { printf 'unknown\n'; return 0; }
      ;;
    reset)
      [[ "$value" =~ ^[1-9][0-9]*$ ]] || { printf 'unknown\n'; return 0; }
      ;;
  esac
  printf '%s\n' "$value"
}

UNIFIED_STATUS=$(fm_claude_quota_or_unknown anthropic-ratelimit-unified-status raw)
UNIFIED_RESET=$(fm_claude_quota_or_unknown anthropic-ratelimit-unified-reset reset)
FIVE_HOUR_STATUS=$(fm_claude_quota_or_unknown anthropic-ratelimit-unified-5h-status raw)
FIVE_HOUR_RESET=$(fm_claude_quota_or_unknown anthropic-ratelimit-unified-5h-reset reset)
FIVE_HOUR_UTILIZATION=$(fm_claude_quota_or_unknown anthropic-ratelimit-unified-5h-utilization utilization)
SEVEN_DAY_STATUS=$(fm_claude_quota_or_unknown anthropic-ratelimit-unified-7d-status raw)
SEVEN_DAY_RESET=$(fm_claude_quota_or_unknown anthropic-ratelimit-unified-7d-reset reset)
SEVEN_DAY_UTILIZATION=$(fm_claude_quota_or_unknown anthropic-ratelimit-unified-7d-utilization utilization)
SEVEN_DAY_SURPASSED_THRESHOLD=$(fm_claude_quota_or_unknown anthropic-ratelimit-unified-7d-surpassed-threshold utilization)
OVERAGE_STATUS=$(fm_claude_quota_or_unknown anthropic-ratelimit-unified-overage-status raw)
OVERAGE_RESET=$(fm_claude_quota_or_unknown anthropic-ratelimit-unified-overage-reset reset)
OVERAGE_UTILIZATION=$(fm_claude_quota_or_unknown anthropic-ratelimit-unified-overage-utilization utilization)
OVERAGE_SURPASSED_THRESHOLD=$(fm_claude_quota_or_unknown anthropic-ratelimit-unified-overage-surpassed-threshold utilization)
OVERAGE_DISABLED_REASON=$(fm_claude_quota_or_unknown anthropic-ratelimit-unified-overage-disabled-reason raw)
REPRESENTATIVE_CLAIM=$(fm_claude_quota_or_unknown anthropic-ratelimit-unified-representative-claim raw)
UPGRADE_PATHS=$(fm_claude_quota_or_unknown anthropic-ratelimit-unified-upgrade-paths raw)
FALLBACK_PERCENTAGE=$(fm_claude_quota_or_unknown anthropic-ratelimit-unified-fallback-percentage utilization)

# Headers are present (HEADER_HITS > 0), but "present" is not "usable": every
# value above can independently degrade to "unknown" (BB2). If every single
# numeric meter did, this reading carries no usable number at all and must
# not exit 0 looking identical to a plan that legitimately has fewer windows.
PARSED_NUMERIC_COUNT=0
for value in "$UNIFIED_RESET" "$FIVE_HOUR_RESET" "$FIVE_HOUR_UTILIZATION" \
  "$SEVEN_DAY_RESET" "$SEVEN_DAY_UTILIZATION" "$SEVEN_DAY_SURPASSED_THRESHOLD" \
  "$OVERAGE_RESET" "$OVERAGE_UTILIZATION" "$OVERAGE_SURPASSED_THRESHOLD" \
  "$FALLBACK_PERCENTAGE"; do
  [ "$value" = unknown ] || PARSED_NUMERIC_COUNT=$((PARSED_NUMERIC_COUNT + 1))
done
if [ "$PARSED_NUMERIC_COUNT" -eq 0 ]; then
  printf 'fm-claude-quota.sh: the probe returned HTTP %s with anthropic-ratelimit-unified-* headers present, but no numeric meter parsed as valid; treating this as a probe failure rather than an all-unknown reading.\n' "$HTTP_CODE" >&2
  exit 1
fi

KNOWN_UNIFIED_HEADER_REGEX='^anthropic-ratelimit-unified-(status|reset|5h-status|5h-reset|5h-utilization|7d-status|7d-reset|7d-utilization|7d-surpassed-threshold|overage-status|overage-reset|overage-utilization|overage-surpassed-threshold|overage-disabled-reason|representative-claim|upgrade-paths|fallback-percentage):'
UNMAPPED_HITS=$(grep -i '^anthropic-ratelimit-unified-' "$HEADERS_FILE" 2>/dev/null | grep -Evic "$KNOWN_UNIFIED_HEADER_REGEX") || UNMAPPED_HITS=0
case "$UNMAPPED_HITS" in ''|*[!0-9]*) UNMAPPED_HITS=0 ;; esac

printf 'probe_http_status=%s\n' "$HTTP_CODE"
printf 'unified_status=%s\n' "$UNIFIED_STATUS"
printf 'unified_reset=%s\n' "$UNIFIED_RESET"
printf 'five_hour_status=%s\n' "$FIVE_HOUR_STATUS"
printf 'five_hour_reset=%s\n' "$FIVE_HOUR_RESET"
printf 'five_hour_utilization=%s\n' "$FIVE_HOUR_UTILIZATION"
printf 'seven_day_status=%s\n' "$SEVEN_DAY_STATUS"
printf 'seven_day_reset=%s\n' "$SEVEN_DAY_RESET"
printf 'seven_day_utilization=%s\n' "$SEVEN_DAY_UTILIZATION"
printf 'seven_day_surpassed_threshold=%s\n' "$SEVEN_DAY_SURPASSED_THRESHOLD"
printf 'overage_status=%s\n' "$OVERAGE_STATUS"
printf 'overage_reset=%s\n' "$OVERAGE_RESET"
printf 'overage_utilization=%s\n' "$OVERAGE_UTILIZATION"
printf 'overage_surpassed_threshold=%s\n' "$OVERAGE_SURPASSED_THRESHOLD"
printf 'overage_disabled_reason=%s\n' "$OVERAGE_DISABLED_REASON"
printf 'representative_claim=%s\n' "$REPRESENTATIVE_CLAIM"
printf 'upgrade_paths=%s\n' "$UPGRADE_PATHS"
printf 'fallback_percentage=%s\n' "$FALLBACK_PERCENTAGE"
printf 'unmapped_unified_headers=%s\n' "$UNMAPPED_HITS"

exit 0
