#!/usr/bin/env bash
# 卸载入口，等价于：bash kcc.sh uninstall
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$DIR/kcc.sh" uninstall "$@"
