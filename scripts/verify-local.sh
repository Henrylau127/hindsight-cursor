#!/usr/bin/env bash
# Local verification: same linux/amd64 build as CI.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMAGE=hindsight-cursor:local bash "${SCRIPT_DIR}/verify.sh"
