#!/usr/bin/env bash
# 一键安装入口，等价于：bash kcc.sh install
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$DIR/kcc.sh" install "$@"
