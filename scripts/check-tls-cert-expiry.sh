#!/bin/bash
#
# TLS certificate expiry monitor.
#
# An expired TLS certificate on a public endpoint is a full outage that arrives
# on a schedule you already know. This check connects to every configured
# production domain, reads the leaf certificate's expiry, and fails (exit 1)
# when any certificate is inside the renewal warning window — so CI can raise
# an alert while there is still time to act.
#
# For each certificate it also classifies whether renewal is automated
# (Let's Encrypt / AWS ACM, or an explicit `auto` annotation) or needs a human
# (anything else, or an explicit `manual` annotation). An auto-renewing cert
# inside the window means the automation has stalled; a manual one means
# someone has to go and reissue it.
#
# Usage:
#   ./scripts/check-tls-cert-expiry.sh
#
# Domain sources (first non-empty wins):
#   TLS_MONITOR_DOMAINS   Newline- or comma-separated list of entries.
#   TLS_MONITOR_DOMAINS_FILE / default devops/tls-monitor-domains.txt
#
# Each entry is:  host[:port] [auto|manual]
#   - port defaults to 443
#   - the second field forces the renewal classification; omit it to
#     auto-detect from the certificate issuer
#   - blank lines and lines starting with '#' are ignored
#
# Environment:
#   TLS_WARN_DAYS         Renewal warning window in days (default 14).
#   TLS_CONNECT_TIMEOUT   Per-host TLS connect timeout in seconds (default 15).
#   TLS_CERT_REPORT_PATH  Path for the machine-readable summary
#                         (default tls-cert-expiry-report.txt).
#
# Flags:
#   --check-config        Parse and validate the domain list only. Makes no
#                         network connections and always exits 0 on a valid
#                         list (used by the workflow's pull_request guard).

set -euo pipefail

CHECK_CONFIG_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --check-config) CHECK_CONFIG_ONLY=1 ;;
    *) echo "❌ Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

WARN_DAYS="${TLS_WARN_DAYS:-14}"
CONNECT_TIMEOUT="${TLS_CONNECT_TIMEOUT:-15}"
REPORT_PATH="${TLS_CERT_REPORT_PATH:-tls-cert-expiry-report.txt}"
DOMAINS_FILE="${TLS_MONITOR_DOMAINS_FILE:-devops/tls-monitor-domains.txt}"

if ! [[ "$WARN_DAYS" =~ ^[0-9]+$ ]]; then
  echo "❌ TLS_WARN_DAYS must be a non-negative integer (got '$WARN_DAYS')." >&2
  exit 2
fi

for binary in openssl date; do
  if ! command -v "$binary" &> /dev/null; then
    echo "❌ Required binary '$binary' not found on PATH." >&2
    exit 2
  fi
done

# ── Assemble the entry list ──────────────────────────────────────────────────
RAW_ENTRIES=""
if [[ -n "${TLS_MONITOR_DOMAINS:-}" ]]; then
  RAW_ENTRIES="$TLS_MONITOR_DOMAINS"
elif [[ -f "$DOMAINS_FILE" ]]; then
  RAW_ENTRIES="$(cat "$DOMAINS_FILE")"
else
  echo "❌ No domains to check: set TLS_MONITOR_DOMAINS or create $DOMAINS_FILE." >&2
  exit 2
fi

# Normalise commas to newlines, strip comments and surrounding whitespace,
# drop blank lines. `while read` keeps this working on bash 3.2 (macOS) where
# `mapfile` is unavailable.
ENTRIES=()
while IFS= read -r line; do
  [[ -n "$line" ]] && ENTRIES+=("$line")
done < <(
  # Strip '#' comments first, THEN split on commas — otherwise a comma inside
  # a comment line would leak its tail in as a bogus entry.
  printf '%s\n' "$RAW_ENTRIES" \
    | sed -e 's/#.*$//' \
    | tr ',' '\n' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | grep -v '^$' || true
)

if [[ ${#ENTRIES[@]} -eq 0 ]]; then
  echo "❌ Domain list is empty after parsing." >&2
  exit 2
fi

if [[ "$CHECK_CONFIG_ONLY" -eq 1 ]]; then
  echo "✅ Parsed ${#ENTRIES[@]} monitored endpoint(s):"
  for entry in "${ENTRIES[@]}"; do
    hp="$(awk '{print $1}' <<< "$entry")"
    fc="$(awk '{print tolower($2)}' <<< "$entry")"
    case "$fc" in
      auto|manual) cls="forced:$fc" ;;
      "")          cls="auto-detect from issuer" ;;
      *) echo "❌ Invalid classification '$fc' for '$hp' (expected auto|manual)." >&2; exit 2 ;;
    esac
    echo "   - ${hp}  (${cls})"
  done
  exit 0
fi

NOW_EPOCH="$(date -u +%s)"
STARTED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# `timeout` ships on the CI runners (coreutils) but not on stock macOS. Fall
# back to running the command directly so local runs still work.
run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout &> /dev/null; then
    timeout "$secs" "$@"
  else
    "$@"
  fi
}

# Portable "date string -> epoch seconds" (GNU date vs BSD/macOS date).
to_epoch() {
  local when="$1"
  date -u -d "$when" +%s 2>/dev/null || date -u -j -f "%b %e %T %Y %Z" "$when" +%s 2>/dev/null
}

# Classify renewal responsibility from the issuer DN.
classify_issuer() {
  local issuer="$1"
  local lower
  lower="$(printf '%s' "$issuer" | tr '[:upper:]' '[:lower:]')"
  if [[ "$lower" == *"let's encrypt"* || "$lower" == *"lets encrypt"* \
        || "$lower" == *"r10"* || "$lower" == *"r11"* || "$lower" == *"e5"* || "$lower" == *"e6"* \
        || "$lower" == *"amazon"* || "$lower" == *"aws"* ]]; then
    echo "auto"
  else
    echo "manual"
  fi
}

echo "=========================================="
echo "🔐 TLS Certificate Expiry Monitor"
echo "=========================================="
echo "Started:        $STARTED_AT"
echo "Warning window: ${WARN_DAYS} day(s)"
echo "Entries:        ${#ENTRIES[@]}"
echo ""

: > "$REPORT_PATH"
{
  echo "# TLS certificate expiry report"
  echo "generated_at=$STARTED_AT"
  echo "warn_days=$WARN_DAYS"
  echo "# host<TAB>port<TAB>renewal<TAB>days_left<TAB>state<TAB>not_after<TAB>issuer"
} >> "$REPORT_PATH"

alerts=0
errors=0

for entry in "${ENTRIES[@]}"; do
  host_port="$(awk '{print $1}' <<< "$entry")"
  forced_class="$(awk '{print tolower($2)}' <<< "$entry")"
  host="${host_port%%:*}"
  port="443"
  [[ "$host_port" == *:* ]] && port="${host_port##*:}"

  cert="$(echo \
    | run_with_timeout "$CONNECT_TIMEOUT" openssl s_client -servername "$host" -connect "${host}:${port}" 2>/dev/null \
    | openssl x509 -noout -enddate -issuer 2>/dev/null || true)"

  if [[ -z "$cert" ]]; then
    echo "  ✗ ${host}:${port} — could not retrieve certificate (unreachable or handshake failed)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$host" "$port" "${forced_class:-unknown}" "NA" "UNREACHABLE" "NA" "NA" >> "$REPORT_PATH"
    errors=$((errors + 1))
    continue
  fi

  not_after="${cert#*notAfter=}"
  not_after="${not_after%%$'\n'*}"
  issuer="$(sed -n 's/^issuer=//p' <<< "$cert")"

  expiry_epoch="$(to_epoch "$not_after" || true)"
  if [[ -z "${expiry_epoch:-}" ]]; then
    echo "  ✗ ${host}:${port} — could not parse notAfter='${not_after}'"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$host" "$port" "${forced_class:-unknown}" "NA" "PARSE_ERROR" "$not_after" "$issuer" >> "$REPORT_PATH"
    errors=$((errors + 1))
    continue
  fi

  days_left=$(( (expiry_epoch - NOW_EPOCH) / 86400 ))

  if [[ "$forced_class" == "auto" || "$forced_class" == "manual" ]]; then
    renewal="$forced_class"
  else
    renewal="$(classify_issuer "$issuer")"
  fi

  if (( expiry_epoch <= NOW_EPOCH )); then
    state="EXPIRED"
  elif (( days_left <= WARN_DAYS )); then
    state="EXPIRING"
  else
    state="OK"
  fi

  case "$state" in
    OK)
      echo "  ✓ ${host}:${port} — ${days_left}d left (${renewal}-renewal), expires ${not_after}"
      ;;
    EXPIRING|EXPIRED)
      alerts=$((alerts + 1))
      if [[ "$renewal" == "auto" ]]; then
        note="auto-renewal expected — automation has NOT renewed in time, investigate the issuing pipeline (certbot/ACM)"
      else
        note="MANUAL ACTION REQUIRED — reissue and deploy this certificate now"
      fi
      echo "  ⚠ ${host}:${port} — ${state}: ${days_left}d left (${renewal}-renewal). ${note}"
      ;;
  esac

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$host" "$port" "$renewal" "$days_left" "$state" "$not_after" "$issuer" >> "$REPORT_PATH"
done

echo ""
echo "------------------------------------------"
echo "Checked ${#ENTRIES[@]} endpoint(s): ${alerts} within/past the warning window, ${errors} unreachable."
echo "Report written to ${REPORT_PATH}"

{
  echo "summary_checked=${#ENTRIES[@]}"
  echo "summary_alerts=${alerts}"
  echo "summary_errors=${errors}"
} >> "$REPORT_PATH"

if (( alerts > 0 || errors > 0 )); then
  exit 1
fi

echo "✅ All monitored certificates are outside the ${WARN_DAYS}-day renewal window."
