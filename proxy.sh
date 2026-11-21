#!/usr/bin/env bash
# One entry point for the OCI SOCKS proxy: instance state, IP rotation,
# SSH tunnel lifecycle, status. No software on the VM.
#
#   ./proxy.sh                 # status + interactive menu
#   ./proxy.sh up              # ensure instance running, (re)start SOCKS tunnel
#   ./proxy.sh tunnel          # (re)start tunnel only, kill any stale ones
#   ./proxy.sh down            # kill all tunnels on this port
#   ./proxy.sh rotate          # new ephemeral IP, then restart tunnel
#   ./proxy.sh status
#   ./proxy.sh ip
#   ./proxy.sh ssh             # interactive shell
#
# Env: SOCKS_PORT=1080  SSH_KEY=~/.ssh/id_rsa  OCI=~/.local/bin/oci
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OCI="${OCI:-$(command -v oci || echo "$HOME/.local/bin/oci")}"
TF="${TF:-$(command -v terraform || echo "$HOME/.local/bin/terraform")}"
PORT="${SOCKS_PORT:-1080}"
KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"
PIDFILE="$SCRIPT_DIR/.socks.pid"
LOGFILE="$SCRIPT_DIR/.socks.log"

# ---------- OCI helpers ----------
instance_id() { "$TF" -chdir="$SCRIPT_DIR" output -raw instance_ocid; }
instance_state() {
  "$OCI" compute instance get --instance-id "$(instance_id)" \
    --query 'data."lifecycle-state"' --raw-output
}
current_ip() {
  "$OCI" compute instance list-vnics --instance-id "$(instance_id)" \
    --query 'data[0]."public-ip"' --raw-output 2>/dev/null || true
}
compartment_id() {
  "$OCI" compute instance get --instance-id "$(instance_id)" \
    --query 'data."compartment-id"' --raw-output
}
availability_domain() {
  "$OCI" compute instance get --instance-id "$(instance_id)" \
    --query 'data."availability-domain"' --raw-output
}
vnic_id() {
  "$OCI" compute instance list-vnics --instance-id "$(instance_id)" \
    --query 'data[0].id' --raw-output
}
private_ip_id() {
  "$OCI" network private-ip list --vnic-id "$(vnic_id)" --all \
    --query 'data[0].id' --raw-output
}

# ---------- tunnel helpers ----------
running() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

port_open() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -q "127.0.0.1:$PORT"
  else
    bash -c "exec 3<>/dev/tcp/127.0.0.1/$PORT" 2>/dev/null
  fi
}

kill_tunnels() {
  local pids="" pid
  [ -f "$PIDFILE" ] && pids="$pids $(cat "$PIDFILE" 2>/dev/null || true)"

  # any ssh process doing dynamic forwarding on this port
  for pid in $(pgrep -f "ssh .* -D .*:${PORT}( |$)" 2>/dev/null || true); do
    [ "$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')" = "ssh" ] && pids="$pids $pid"
  done

  # whoever is actually bound to the port
  if command -v ss >/dev/null 2>&1; then
    for pid in $(ss -ltnp 2>/dev/null | awk -v p=":$PORT" '$4 ~ p' \
      | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u); do
      pids="$pids $pid"
    done
  fi

  for pid in $(printf '%s\n' $pids | sort -u); do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
  done
  rm -f "$PIDFILE"

  local i=0
  while port_open && [ "$i" -lt 10 ]; do sleep 0.3; i=$((i + 1)); done
  if port_open; then
    echo "warning: 127.0.0.1:$PORT still in use" >&2
    return 1
  fi
  return 0
}

ensure_running() {
  local st
  st="$(instance_state)"
  case "$st" in
    RUNNING) ;;
    STOPPED)
      echo "instance is STOPPED, starting..."
      "$OCI" compute instance action --instance-id "$(instance_id)" \
        --action START --wait-for-state RUNNING >/dev/null
      ;;
    STARTING|STOPPING)
      "$OCI" compute instance get --instance-id "$(instance_id)" \
        --wait-for-state RUNNING >/dev/null
      ;;
    *) echo "instance state is $st; cannot start" >&2; exit 1 ;;
  esac
}

ensure_ip() {
  local ip
  ip="$(current_ip)"
  if [ -z "$ip" ] || [ "$ip" = "null" ]; then
    echo "no public IP, assigning ephemeral..."
    "$OCI" network public-ip create \
      --compartment-id "$(compartment_id)" \
      --lifetime EPHEMERAL \
      --private-ip-id "$(private_ip_id)" \
      --wait-for-state ASSIGNED >/dev/null
  fi
}

start_tunnel() {
  kill_tunnels || exit 1
  ensure_ip
  local ip
  ip="$(current_ip)"
  [ -n "$ip" ] || { echo "no public IP" >&2; exit 1; }

  nohup ssh -N -D "127.0.0.1:$PORT" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -o ConnectTimeout=15 \
    -i "$KEY" "ubuntu@$ip" >"$LOGFILE" 2>&1 &
  echo $! >"$PIDFILE"

  local tries=0
  while ! port_open; do
    tries=$((tries + 1))
    if ! running; then
      echo "tunnel failed; last log:" >&2
      tail -5 "$LOGFILE" >&2 || true
      rm -f "$PIDFILE"
      exit 1
    fi
    if [ "$tries" -ge 25 ]; then
      echo "timed out waiting for 127.0.0.1:$PORT" >&2
      exit 1
    fi
    sleep 1
  done

  echo "SOCKS5 up: 127.0.0.1:$PORT -> $ip (pid $(cat "$PIDFILE"))"
}

# ---------- IP rotation ----------
rotate_ip() {
  local comp ad priv old_ocid old_ip new_ip
  comp="$(compartment_id)"
  ad="$(availability_domain)"
  priv="$(private_ip_id)"

  old_ocid="$("$OCI" network public-ip list --compartment-id "$comp" \
    --scope AVAILABILITY_DOMAIN --availability-domain "$ad" --lifetime EPHEMERAL --all \
    --query "data[?\"private-ip-id\"=='$priv'].id | [0]" --raw-output)"
  old_ip="$("$OCI" network public-ip list --compartment-id "$comp" \
    --scope AVAILABILITY_DOMAIN --availability-domain "$ad" --lifetime EPHEMERAL --all \
    --query "data[?\"private-ip-id\"=='$priv'].[\"ip-address\"] | [0][0]" --raw-output)"

  if [ -n "${old_ocid:-}" ] && [ "$old_ocid" != "null" ]; then
    "$OCI" network public-ip delete --public-ip-id "$old_ocid" --force
  fi

  new_ip="$("$OCI" network public-ip create \
    --compartment-id "$comp" --lifetime EPHEMERAL \
    --private-ip-id "$priv" --wait-for-state ASSIGNED \
    --query 'data."ip-address"' --raw-output)"

  echo "old: ${old_ip:-none}"
  echo "new: $new_ip"
}

# ---------- commands ----------
cmd_status() {
  local st ip
  st="$(instance_state 2>/dev/null || echo unknown)"
  ip="$(current_ip)"
  echo "instance : $st"
  echo "public ip: ${ip:-none}"
  if running; then
    echo "tunnel   : up (pid $(cat "$PIDFILE")) -> 127.0.0.1:$PORT"
  else
    echo "tunnel   : down"
  fi
  echo "socks url: socks5h://127.0.0.1:$PORT"
}

cmd_up() { ensure_running; start_tunnel; }
cmd_rotate() { kill_tunnels || true; rotate_ip; start_tunnel; }
cmd_ssh() { exec ssh -i "$KEY" "ubuntu@$(current_ip)"; }

menu() {
  while true; do
    echo
    cmd_status
    echo
    echo "  1) up (tunnel)   2) down        3) rotate IP"
    echo "  4) ssh shell     5) status      6) quit"
    read -rp "> " choice || exit 0
    case "$choice" in
      1) cmd_up ;;
      2) kill_tunnels; echo "tunnel down" ;;
      3) cmd_rotate ;;
      4) cmd_ssh ;;
      5) ;;
      6) exit 0 ;;
      *) echo "?" ;;
    esac
  done
}

case "${1:-}" in
  up) cmd_up ;;
  tunnel) start_tunnel ;;
  down) kill_tunnels && echo "tunnel down" ;;
  restart) start_tunnel ;;
  rotate) cmd_rotate ;;
  status) cmd_status ;;
  ip) current_ip ;;
  ssh) cmd_ssh ;;
  menu | "") if [ -t 0 ] && [ -t 1 ]; then menu; else cmd_status; fi ;;
  *) echo "usage: $0 [up|tunnel|down|rotate|restart|status|ip|ssh|menu]" >&2; exit 1 ;;
esac
