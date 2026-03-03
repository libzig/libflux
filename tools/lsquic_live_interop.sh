#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${LIBFLUX_LIVE_INTEROP_ENDPOINT:-}" ]]; then
  echo "[lsquic-live] LIBFLUX_LIVE_INTEROP_ENDPOINT is required"
  exit 1
fi

echo "[lsquic-live] target endpoint: ${LIBFLUX_LIVE_INTEROP_ENDPOINT}"
echo "[lsquic-live] placeholder live interop execution completed"
