#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
relay_binary="${WN_TEST_RELAY_BINARY:-$PWD/build/TestRelay/debug/white-noise-sync-test-relay}"
relay_port="${WN_TEST_RELAY_PORT:-18181}"
mkdir -p build
# Refuse to reuse or stop a server belonging to another run.
python3 - "$relay_port" <<'PY'
import socket, sys
port = int(sys.argv[1])
assert 1 <= port <= 65535
with socket.socket() as listener:
    listener.bind(('127.0.0.1', port))
PY
"$relay_binary" --port "$relay_port" >build/test-relay.log 2>&1 &
relay_pid=$!
cleanup() {
  if kill -0 "$relay_pid" 2>/dev/null; then
    kill -INT "$relay_pid"
  fi
  wait "$relay_pid" || true
}
trap cleanup EXIT
python3 - "$relay_pid" "$relay_port" <<'PY'
import os, socket, sys, time
pid, port = map(int, sys.argv[1:])
deadline = time.monotonic() + 15
while True:
    os.kill(pid, 0)
    try:
        with socket.create_connection(('127.0.0.1', port), timeout=1):
            break
    except ConnectionRefusedError:
        if time.monotonic() >= deadline:
            raise TimeoutError('Owned test relay did not start')
        time.sleep(0.05)
PY
python3 scripts/test-relay/smoke.py --port "$relay_port"
export TEST_RUNNER_WN_NATIVE_TEST_RELAY_URL="ws://127.0.0.1:$relay_port"
bash scripts/test.sh "$@"
