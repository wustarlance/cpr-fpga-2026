#!/usr/bin/env bash
set -euo pipefail
task_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$task_here/run.py" tb_bmp_scan
