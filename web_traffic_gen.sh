#!/usr/bin/env bash
# =============================================================================
# web_traffic_gen.sh — consistent synthetic web traffic generator for Linux
#
# Repeatedly fetches a set of web pages (Google, Stuff, Amazon by default),
# with retries + exponential backoff, and logs per-request timing metrics
# (DNS / TCP / TLS / TTFB / total) to CSV. Useful for keeping a test link
# "warm", validating QoS/shaping, or baselining a circuit.
#
# Modes:
#   curl     - lightweight HTTP(S) GETs (default, no GUI needed)
#   headless - full page loads incl. JS/assets via headless Chromium/Chrome
#   browser  - opens real browser tabs via xdg-open (needs a desktop session)
#
# Usage examples:
#   ./web_traffic_gen.sh                          # run forever, defaults
#   ./web_traffic_gen.sh -i 10 -d 3600            # every 10s for 1 hour
#   ./web_traffic_gen.sh -m headless -c 3 -n 100  # 100 rounds, 3 parallel
#   ./web_traffic_gen.sh -u https://example.com -u https://nzherald.co.nz
#   ./web_traffic_gen.sh -I eth1                  # source from a specific NIC
#
# Stop with Ctrl+C — a summary is printed on exit.
# =============================================================================

set -uo pipefail

# ----------------------------- Defaults --------------------------------------
DEFAULT_URLS=(
  "https://www.google.com"
  "https://www.stuff.co.nz"
  "https://www.amazon.com"
)
URLS=()
MODE="curl"           # curl | headless | browser
INTERVAL=30           # seconds between rounds
JITTER=5              # +/- random seconds added to interval
ROUNDS=0              # 0 = unlimited
DURATION=0            # seconds, 0 = unlimited
CONCURRENCY=1         # parallel fetches per round
RETRIES=3             # retry attempts per URL after first failure
BACKOFF=2             # initial backoff seconds (doubles each retry)
TIMEOUT=20            # per-request timeout seconds
IFACE=""              # optional source interface / IP for curl
IPVER=""              # -4 or -6 to force IP version
LOGDIR="./traffic_logs"
QUIET=0

USER_AGENTS=(
  "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
  "Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:131.0) Gecko/20100101 Firefox/131.0"
)

# ----------------------------- Helpers ---------------------------------------
usage() {
  sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
  cat <<EOF
Options:
  -u URL     Add a URL (repeatable; replaces the default list)
  -f FILE    Read URLs from file (one per line, # comments ok)
  -m MODE    curl | headless | browser          (default: $MODE)
  -i SEC     Interval between rounds            (default: $INTERVAL)
  -j SEC     Random jitter +/- on interval      (default: $JITTER)
  -n NUM     Number of rounds, 0 = unlimited    (default: $ROUNDS)
  -d SEC     Total run duration, 0 = unlimited  (default: $DURATION)
  -c NUM     Parallel fetches per round         (default: $CONCURRENCY)
  -r NUM     Retries per URL on failure         (default: $RETRIES)
  -b SEC     Initial retry backoff (doubles)    (default: $BACKOFF)
  -t SEC     Per-request timeout                (default: $TIMEOUT)
  -I IFACE   Source interface or IP (curl mode)
  -4 | -6    Force IPv4 / IPv6 (curl mode)
  -l DIR     Log directory                      (default: $LOGDIR)
  -q         Quiet (log to file only)
  -h         Help
EOF
  exit 0
}

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { local msg="[$(ts)] $*"; echo "$msg" >> "$RUNLOG"; [[ $QUIET -eq 1 ]] || echo "$msg"; }
rand_ua() { echo "${USER_AGENTS[RANDOM % ${#USER_AGENTS[@]}]}"; }

find_chrome() {
  for b in chromium chromium-browser google-chrome google-chrome-stable; do
    command -v "$b" >/dev/null 2>&1 && { echo "$b"; return 0; }
  done
  return 1
}

# ----------------------------- Arg parsing -----------------------------------
while getopts ":u:f:m:i:j:n:d:c:r:b:t:I:l:46qh" opt; do
  case $opt in
    u) URLS+=("$OPTARG") ;;
    f) while IFS= read -r line; do
         line="${line%%#*}"; line="${line//[[:space:]]/}"
         [[ -n "$line" ]] && URLS+=("$line")
       done < "$OPTARG" ;;
    m) MODE="$OPTARG" ;;
    i) INTERVAL="$OPTARG" ;;
    j) JITTER="$OPTARG" ;;
    n) ROUNDS="$OPTARG" ;;
    d) DURATION="$OPTARG" ;;
    c) CONCURRENCY="$OPTARG" ;;
    r) RETRIES="$OPTARG" ;;
    b) BACKOFF="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    I) IFACE="$OPTARG" ;;
    4) IPVER="-4" ;;
    6) IPVER="-6" ;;
    l) LOGDIR="$OPTARG" ;;
    q) QUIET=1 ;;
    h) usage ;;
    :) echo "Option -$OPTARG requires an argument" >&2; exit 1 ;;
    \?) echo "Unknown option -$OPTARG" >&2; exit 1 ;;
  esac
done
[[ ${#URLS[@]} -eq 0 ]] && URLS=("${DEFAULT_URLS[@]}")

# ----------------------------- Pre-flight ------------------------------------
case "$MODE" in
  curl)
    command -v curl >/dev/null || { echo "curl not found (apt install curl)"; exit 1; } ;;
  headless)
    CHROME=$(find_chrome) || { echo "Chromium/Chrome not found (apt install chromium)"; exit 1; } ;;
  browser)
    command -v xdg-open >/dev/null || { echo "xdg-open not found"; exit 1; }
    [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] || { echo "No desktop session (DISPLAY/WAYLAND_DISPLAY unset)"; exit 1; } ;;
  *) echo "Invalid mode: $MODE"; exit 1 ;;
esac

mkdir -p "$LOGDIR"
STAMP=$(date '+%Y%m%d_%H%M%S')
CSV="$LOGDIR/traffic_${STAMP}.csv"
RUNLOG="$LOGDIR/traffic_${STAMP}.log"
STATS="$(mktemp -d)"
echo "timestamp,round,url,attempt,result,http_code,dns_s,connect_s,tls_s,ttfb_s,total_s,bytes,remote_ip" > "$CSV"

# ----------------------------- Fetch functions -------------------------------
# Single attempt. Echoes CSV metric fields; returns 0 on success.
fetch_curl() {
  local url="$1" out rc code
  local args=(-s -o /dev/null -L --compressed --max-time "$TIMEOUT"
              -A "$(rand_ua)"
              -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
              -H "Accept-Language: en-NZ,en;q=0.9"
              -w '%{http_code},%{time_namelookup},%{time_connect},%{time_appconnect},%{time_starttransfer},%{time_total},%{size_download},%{remote_ip}')
  [[ -n "$IFACE" ]] && args+=(--interface "$IFACE")
  [[ -n "$IPVER" ]] && args+=("$IPVER")
  out=$(curl "${args[@]}" "$url" 2>/dev/null); rc=$?
  code="${out%%,*}"
  echo "$out"
  [[ $rc -eq 0 && "$code" =~ ^[23] ]]
}

fetch_headless() {
  local url="$1" start end rc bytes
  start=$(date +%s.%N)
  bytes=$(timeout "$TIMEOUT" "$CHROME" --headless=new --disable-gpu --no-sandbox \
            --user-agent="$(rand_ua)" --dump-dom "$url" 2>/dev/null | wc -c); rc=$?
  end=$(date +%s.%N)
  local total; total=$(awk "BEGIN{printf \"%.3f\", $end-$start}")
  echo "-,-,-,-,-,$total,$bytes,-"
  [[ $rc -eq 0 && $bytes -gt 500 ]]
}

fetch_browser() {
  local url="$1"
  xdg-open "$url" >/dev/null 2>&1 &
  echo "-,-,-,-,-,-,-,-"
  return 0
}

# Fetch with retries + exponential backoff
fetch_with_retry() {
  local url="$1" round="$2" attempt=0 wait="$BACKOFF" metrics result
  local key; key=$(echo -n "$url" | md5sum | cut -c1-8)
  while :; do
    attempt=$((attempt + 1))
    if metrics=$("fetch_$MODE" "$url"); then result="OK"; else result="FAIL"; fi
    echo "$(ts),$round,$url,$attempt,$result,$metrics" >> "$CSV"

    if [[ $result == OK ]]; then
      local total; total=$(cut -d, -f6 <<<"$metrics")
      log "  OK    $url (attempt $attempt, http $(cut -d, -f1 <<<"$metrics"), ${total}s)"
      echo ok >> "$STATS/$key.ok"; echo "$url" > "$STATS/$key.url"
      return 0
    fi
    if (( attempt > RETRIES )); then
      log "  FAIL  $url — gave up after $attempt attempts (last: $(cut -d, -f1 <<<"$metrics"))"
      echo fail >> "$STATS/$key.fail"; echo "$url" > "$STATS/$key.url"
      return 1
    fi
    log "  RETRY $url (attempt $attempt failed, http $(cut -d, -f1 <<<"$metrics"); backoff ${wait}s)"
    echo r >> "$STATS/$key.retry"
    sleep "$wait"; wait=$((wait * 2))
  done
}

# ----------------------------- Summary / cleanup -----------------------------
summary() {
  trap - INT TERM EXIT
  wait 2>/dev/null
  echo
  log "================ SUMMARY ================"
  log "Rounds completed: $ROUND   Runtime: $(( $(date +%s) - START ))s"
  printf "%-40s %6s %6s %6s\n" "URL" "OK" "FAIL" "RETRY" | tee -a "$RUNLOG"
  for f in "$STATS"/*.url; do
    [[ -e "$f" ]] || continue
    local k; k=$(basename "$f" .url)
    printf "%-40s %6s %6s %6s\n" "$(cat "$f")" \
      "$(cat "$STATS/$k.ok" 2>/dev/null | wc -l)" \
      "$(cat "$STATS/$k.fail" 2>/dev/null | wc -l)" \
      "$(cat "$STATS/$k.retry" 2>/dev/null | wc -l)" | tee -a "$RUNLOG"
  done
  if [[ $MODE == curl ]]; then
    log "Avg total time per URL (successful requests):"
    awk -F, 'NR>1 && $5=="OK"{s[$3]+=$11; n[$3]++}
             END{for(u in s) printf "  %-38s %.3fs (n=%d)\n", u, s[u]/n[u], n[u]}' "$CSV" | tee -a "$RUNLOG"
  fi
  log "CSV: $CSV"
  log "Log: $RUNLOG"
  rm -rf "$STATS"
  exit 0
}
trap summary INT TERM EXIT

# ----------------------------- Main loop -------------------------------------
START=$(date +%s)
ROUND=0
log "Starting traffic generator — mode=$MODE interval=${INTERVAL}s±${JITTER}s concurrency=$CONCURRENCY retries=$RETRIES timeout=${TIMEOUT}s"
log "Targets: ${URLS[*]}"

while :; do
  (( ROUNDS > 0 && ROUND >= ROUNDS )) && break
  (( DURATION > 0 && $(date +%s) - START >= DURATION )) && break
  ROUND=$((ROUND + 1))
  log "Round $ROUND"

  running=0
  for url in "${URLS[@]}"; do
    fetch_with_retry "$url" "$ROUND" &
    running=$((running + 1))
    if (( running >= CONCURRENCY )); then wait -n; running=$((running - 1)); fi
  done
  wait

  (( ROUNDS > 0 && ROUND >= ROUNDS )) && break
  if (( JITTER > 0 )); then
    sleep_for=$(( INTERVAL + (RANDOM % (2 * JITTER + 1)) - JITTER ))
  else
    sleep_for=$INTERVAL
  fi
  (( sleep_for < 1 )) && sleep_for=1
  sleep "$sleep_for"
done
