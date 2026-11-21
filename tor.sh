#!/usr/bin/env bash
# Local Tor SOCKS proxy. Tor itself is the proxy: no SSH, no VM.
#
#   ./tor.sh start [any|us|de|us,de]   # default: any (no geo pin)
#   ./tor.sh stop
#   ./tor.sh restart [cc]
#   ./tor.sh status
#   ./tor.sh ip                        # current exit IP + geo
#   ./tor.sh newnym                    # new circuits -> show old/new IP
#   ./tor.sh curl <curl args...>       # curl through Tor
#
# Env: TOR_SOCKS_PORT=9050  TOR_CONTROL_PORT=9051
#      TOR_ENTRY=us         # optional: pin guard country
#      TOR_EXTRA="--MaxCircuitDirtiness 1800 ..."
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${TOR_SOCKS_PORT:-9050}"
CTRL="${TOR_CONTROL_PORT:-9051}"
DIR="$SCRIPT_DIR/.tor"
PIDFILE="$DIR/tor.pid"
LOGFILE="$DIR/tor.log"
COUNTRYFILE="$DIR/country"
TORRC="$DIR/empty.torrc"
COOKIE="$DIR/data/control_auth_cookie"

mkdir -p "$DIR"
: >"$TORRC"

normalize_cc() {
  local raw="${1// /}" out="" p
  if [[ "$raw" == *"{"* ]]; then printf '%s' "$raw"; return; fi
  IFS=',' read -ra parts <<<"$raw"
  for p in "${parts[@]}"; do
    [ -n "$p" ] || continue
    out+="${out:+,}{$p}"
  done
  printf '%s' "$out"
}

running() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

start() {
  local cc="${1:-$(cat "$COUNTRYFILE" 2>/dev/null || echo any)}" nodes="" args=()
  case "$cc" in
    any | world | "") nodes="" ;;
    *) nodes="$(normalize_cc "$cc")" ;;
  esac

  if running; then
    echo "tor already up (pid $(cat "$PIDFILE"), exit $(cat "$COUNTRYFILE" 2>/dev/null || echo any))"
    return 0
  fi

  : >"$LOGFILE"
  args=(-f "$TORRC" --SocksPort "$PORT" --DataDirectory "$DIR/data"
    --ControlPort "127.0.0.1:$CTRL" --CookieAuthentication 1
    --Log "notice file $LOGFILE")
  if [ -n "$nodes" ]; then
    args+=(--ExitNodes "$nodes")
    [ "${TOR_STRICT:-1}" = "1" ] && args+=(--StrictNodes 1)
  fi
  [ -n "${TOR_ENTRY:-}" ] && args+=(--EntryNodes "$(normalize_cc "$TOR_ENTRY")")
  if [ -n "${TOR_EXTRA:-}" ]; then
    local extra
    read -r -a extra <<<"$TOR_EXTRA"
    args+=("${extra[@]}")
  fi

  setsid tor "${args[@]}" >/dev/null 2>&1 &
  echo $! >"$PIDFILE"
  printf '%s' "$cc" >"$COUNTRYFILE"

  local i
  for i in $(seq 1 90); do
    if grep -q 'Bootstrapped 100' "$LOGFILE" 2>/dev/null; then
      for _ in $(seq 1 15); do [ -f "$COOKIE" ] && break; sleep 1; done
      echo "tor up: 127.0.0.1:$PORT  (exit ${nodes:-any})  control 127.0.0.1:$CTRL"
      return 0
    fi
    if ! running; then
      echo "tor exited; log tail:" >&2
      tail -5 "$LOGFILE" >&2 || true
      return 1
    fi
    sleep 1
  done
  echo "timed out waiting for bootstrap" >&2
  tail -5 "$LOGFILE" >&2 || true
  return 1
}

stop() {
  if running; then kill "$(cat "$PIDFILE")" 2>/dev/null || true; fi
  rm -f "$PIDFILE"
  echo "tor stopped"
}

# ---- control port ----  (authenticate, then run one or more commands)
control() {
  local hex
  [ -f "$COOKIE" ] || { echo "no control cookie yet" >&2; return 1; }
  hex="$(od -An -tx1 -v "$COOKIE" | tr -d ' \n')"
  python3 - "$hex" "$CTRL" "$@" <<'PY'
import socket, sys
hexcookie, port, cmds = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
s = socket.create_connection(("127.0.0.1", port), 5)
s.sendall((f"AUTHENTICATE {hexcookie}\r\n" + "\r\n".join(cmds) + "\r\nQUIT\r\n").encode())
s.settimeout(4)
try:
    print(s.recv(8192).decode(errors="replace"))
except Exception:
    pass
s.close()
PY
}

# ---- exit IP ----
# Query the SAME destination the browser check uses, so old/new match.
exit_ip() {
  local ip="" json
  ip="$(curl -s --max-time 20 --socks5-hostname "127.0.0.1:$PORT" \
    https://api.ipify.org 2>/dev/null | tr -d '[:space:]' || true)"
  if ! [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ip=""
    json="$(curl -s --max-time 25 --socks5-hostname "127.0.0.1:$PORT" \
      https://check.torproject.org/api/ip 2>/dev/null || true)"
    ip="$(printf '%s' "$json" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("IP","") or "")
except Exception: print("")' 2>/dev/null || true)"
  fi
  [ -n "$ip" ] || return 1
  local geo
  geo="$(curl -s --max-time 10 "https://ipinfo.io/$ip/json" | python3 -c \
    'import sys,json;d=json.load(sys.stdin);print(d.get("city"),d.get("region"),d.get("country"),d.get("org"))' 2>/dev/null || true)"
  echo "$ip ${geo}"
}

status() {
  if running; then
    echo "tor   : up (pid $(cat "$PIDFILE"))  socks 127.0.0.1:$PORT"
    echo "exit  : $(cat "$COUNTRYFILE" 2>/dev/null || echo any)"
    local info
    if info="$(exit_ip)"; then echo "ip    : $info"; else echo "ip    : (query failed)"; fi
    echo "change: ./tor.sh newnym   (circuit lasts MaxCircuitDirtiness=${MAX_DIRTINESS:-600}s)"
  else
    echo "tor   : down"
  fi
}

newnym() {
  if ! running; then echo "tor is down; run ./tor.sh start" >&2; exit 1; fi
  local plain=0 before_full after_full before after net
  [ "${1:-}" = "--plain" ] && plain=1

  # Recover from a previously stuck exclusion (e.g. a country with one /24).
  before_full="$(exit_ip || true)"
  if [ -z "$before_full" ]; then
    control 'SETCONF ExcludeExitNodes=' 'SIGNAL NEWNYM' >/dev/null 2>&1 || true
    sleep 4
    before_full="$(exit_ip || true)"
  fi
  before="$(printf '%s' "$before_full" | awk '{print $1}')"
  if [ -z "$before" ]; then
    echo "could not read current exit — this country may have no reachable exits." >&2
    echo "try: ./tor.sh restart any   (or another country)" >&2
    exit 1
  fi

  if [ "$plain" = 1 ]; then
    control 'SIGNAL NEWNYM' >/dev/null 2>&1 || true
  else
    net="$(printf '%s' "$before" | cut -d. -f1-3).0/24"
    control "SETCONF ExcludeExitNodes=$net" 'SIGNAL NEWNYM' >/dev/null 2>&1 || true
  fi

  sleep 4
  after_full="$(exit_ip || true)"
  after="$(printf '%s' "$after_full" | awk '{print $1}')"

  # Fallback: no alternate network in this country -> plain NEWNYM, don't deadlock.
  if [ "$plain" = 0 ] && [ -z "$after" ]; then
    control 'SETCONF ExcludeExitNodes=' 'SIGNAL NEWNYM' >/dev/null 2>&1 || true
    sleep 4
    after_full="$(exit_ip || true)"
    after="$(printf '%s' "$after_full" | awk '{print $1}')"
    echo "no alternate exit network in this country — fell back to plain NEWNYM"
    plain=1
  fi

  echo "old: ${before_full:-?}"
  echo "new: ${after_full:-?}"
  if [ "$plain" = 0 ]; then
    echo "excluding $net for new circuits (cleared on next newnym / restart)"
  fi
  if [ "$before" = "${after:-}" ]; then
    echo "(same IP — NEWNYM is rate-limited ~1/10s; wait a few seconds and retry)"
  fi
  return 0
}

case "${1:-status}" in
  start) start "${2:-any}" ;;
  stop) stop ;;
  restart)
    stop
    sleep 2
    start "${2:-$(cat "$COUNTRYFILE" 2>/dev/null || echo any)}"
    ;;
  status) status ;;
  ip)
    if ! running; then echo "tor is down; run ./tor.sh start" >&2; exit 1; fi
    exit_ip || { echo "query failed" >&2; exit 1; }
    ;;
  newnym | new | rotate)
    newnym "${2:-}"
    ;;
  clear)
    if ! running; then echo "tor is down" >&2; exit 1; fi
    control 'SETCONF ExcludeExitNodes=' 'SIGNAL NEWNYM' >/dev/null 2>&1 || true
    echo "exit exclusions cleared"
    ;;
  curl)
    shift
    if ! running; then echo "tor is down; run ./tor.sh start" >&2; exit 1; fi
    exec curl --socks5-hostname "127.0.0.1:$PORT" "$@"
    ;;
  *)
    echo "usage: $0 [start [any|us|de|..] | stop | restart [cc] | status | ip | newnym | curl ...]" >&2
    exit 1
    ;;
esac
