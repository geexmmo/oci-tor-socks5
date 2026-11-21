#!/usr/bin/env bash
# Compatibility wrapper: use ./proxy.sh
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/proxy.sh" rotate
