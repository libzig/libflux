#!/usr/bin/env bash
set -euo pipefail

echo "[interop-smoke] running in-memory interop scenario test"
zig build test --summary all

if [[ "${LIBFLUX_RUN_LIVE_INTEROP:-0}" != "1" ]]; then
  echo "[interop-smoke] skipping live LSQUIC interop (set LIBFLUX_RUN_LIVE_INTEROP=1)"
  exit 0
fi

if [[ -z "${LIBFLUX_LIVE_INTEROP_ENDPOINT:-}" ]]; then
  echo "[interop-smoke] LIBFLUX_LIVE_INTEROP_ENDPOINT not set; skipping live run"
  exit 0
fi

if [[ ! -x "./tools/lsquic_live_interop.sh" ]]; then
  echo "[interop-smoke] live interop script missing or not executable: ./tools/lsquic_live_interop.sh"
  exit 1
fi

echo "[interop-smoke] running live LSQUIC interop"
./tools/lsquic_live_interop.sh
