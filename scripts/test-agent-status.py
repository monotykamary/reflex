#!/usr/bin/env python3
"""Test the real Bend status adapter against a disposable Unix socket, not live agents."""

import json
import os
from pathlib import Path
import socketserver
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parent.parent
STATUSES = {
    "w1:p1": {"agent": {"agent_status": "idle"}},
    "w1:p2": {"agent": {"agent_status": "working"}},
    "w1:p3": {"agent": {"agent_status": "blocked"}},
    "named-agent": {"agent": {"agent_status": "done"}},
    "w1:p5": {"agent": {"agent_status": "unknown"}},
    "missing-agent": {},
    "missing-status": {"agent": {}},
    "old-pane-payload": {"pane": {"agent_status": "idle"}},
    "failed-read": None,
}


def main():
    errors, seen = [], []

    class Handler(socketserver.StreamRequestHandler):
        def handle(self):
            try:
                self.connection.settimeout(3)
                request = json.loads(self.rfile.readline(4096))
                params = request.get("params", {})
                target = params.get("target")
                if request.get("method") != "agent.get" or params != {"target": target} or target not in STATUSES:
                    raise ValueError(f"expected agent.get {{target}}, got {request!r}")
                seen.append(target)
                result = STATUSES[target]
                response = {"id": request["id"]}
                if result is None:
                    response["error"] = {"code": "agent_not_found", "message": "gone"}
                else:
                    response["result"] = result
                self.wfile.write((json.dumps(response) + "\n").encode())
            except Exception as error:
                errors.append(str(error))

    with tempfile.TemporaryDirectory(prefix="reflex-agent-status-") as work:
        binary = str(Path(work) / "status")
        started = time.monotonic()
        subprocess.run(
            ["bend", "daemon/tests/status.bend", "-o", binary],
            cwd=ROOT, check=True, timeout=120, capture_output=True, text=True,
        )
        built = time.monotonic()
        socket_path = str(Path(work) / "herdr.sock")
        with socketserver.UnixStreamServer(socket_path, Handler) as server:
            worker = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
            worker.start()
            try:
                run = subprocess.run(
                    [binary], cwd=ROOT, timeout=10, capture_output=True, text=True,
                    env={**os.environ, "REFLEX_TEST_SOCKET": socket_path},
                )
            finally:
                server.shutdown()
                worker.join(timeout=1)
        if errors or seen != list(STATUSES) or run.returncode or run.stdout.strip() != "agent status checks passed":
            raise RuntimeError(f"adapter regression: {errors=} {seen=}\n{run.stdout}\n{run.stderr}")
        print(f"agent.get status adapter: {len(seen)} cases passed (build {built - started:.1f}s, probe {time.monotonic() - built:.1f}s)")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        raise SystemExit(error.stdout + error.stderr) from error
