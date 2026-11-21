#!/usr/bin/env bash
# Compatibility wrapper: use ./proxy.sh up|down|restart|status
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-start}" in
  start) exec "$SCRIPT_DIR/proxy.sh" tunnel ;;
  stop) exec "$SCRIPT_DIR/proxy.sh" down ;;
  restart) exec "$SCRIPT_DIR/proxy.sh" restart ;;
  status) exec "$SCRIPT_DIR/proxy.sh" status ;;
  *) echo "usage: $0 [start|stop|restart|status]" >&2; exit 1 ;;
esac
