#!/usr/bin/env python3
"""reflexd end to end on herdr-core: the real daemon against a disposable core (never your
own), no herdr anywhere. Its API lists the core's agents, a prompt reaches one and is
answered, a session starts there (pi, with no request: nothing is sent to any model) with
the session id Reflex chose, and closing it ends it.

Needs Bend, a C compiler, pi, and hc (on PATH, or REFLEX_TEST_HC=/path/to/herdr-core).
"""

import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
HC = os.environ.get("REFLEX_TEST_HC") or shutil.which("hc") or shutil.which("herdr-core")
TOKEN = "rxtest-token"
R = r"""r(){ printf '\033]7501;%s\033\\' "$1"; }; """
ECHO = R + "r state=idle:app=pi; stty -echo; while read -r l; do r state=working; echo \"got:$l\"; r state=done; done"


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def api(port, path, body=None):
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=None if body is None else json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read())


def until(what, fn, timeout=20):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        v = fn()
        if v:
            return v
        time.sleep(0.4)
    raise SystemExit(f"timed out waiting for {what}")


def main():
    if not HC:
        raise SystemExit("hc not found: install herdr-core or set REFLEX_TEST_HC")
    run_dir = tempfile.mkdtemp(prefix="rxd", dir="/tmp")
    work = Path(tempfile.mkdtemp(prefix="reflex-core-daemon-"))
    core_env = {**os.environ, "HC_SESSION": "rxdaemon", "XDG_RUNTIME_DIR": run_dir,
                "XDG_STATE_HOME": f"{work}/state", "XDG_CONFIG_HOME": f"{work}/config"}
    for k in ("HC_SOCKET", "HC_TERMINAL_ID"):
        core_env.pop(k, None)
    sock = f"{run_dir}/herdr-core/rxdaemon.sock"
    daemon = None
    port = free_port()
    try:
        subprocess.run(["bend", "daemon/main.bend", "-o", f"{work}/reflexd"], cwd=ROOT, check=True, timeout=600,
                       capture_output=True, env={**os.environ, "BEND_NO_TELEMETRY": "1"})
        subprocess.run([HC, "run", "--bg", "--no-parent", "--name", "echo", "--", "sh", "-c", ECHO],
                       env=core_env, check=True, capture_output=True, timeout=30)
        (work / "data").mkdir()
        (work / "roots" / "proj").mkdir(parents=True)
        log = open(work / "reflexd.log", "w")
        daemon = subprocess.Popen([f"{work}/reflexd"], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, env={
            **core_env, "REFLEX_TOKEN": TOKEN, "REFLEX_PORT": str(port), "REFLEX_BIND": "127.0.0.1",
            "REFLEX_DATA": f"{work}/data", "REFLEX_WEB": str(ROOT / "web"), "REFLEX_SCAN": str(ROOT / "scripts/reflex-scan.sh"),
            "REFLEX_FORK": str(ROOT / "scripts/reflex-fork.sh"), "REFLEX_ROOTS": f"{work}/roots",
            "REFLEX_CORE_SOCKET": sock, "REFLEX_HERDR_SOCKET": f"{work}/no-herdr.sock", "REFLEX_BACKEND": "core",
            "SHELL": "/bin/zsh"})
        until("reflexd", lambda: _try(lambda: api(port, "/api/health")))

        state = until("the core's agents", lambda: (lambda s: s if any(a["name"] == "echo" for a in s.get("agents", [])) else None)(api(port, "/api/state")))
        echo = next(a for a in state["agents"] if a["name"] == "echo")
        assert echo["kind"] == "pi" and echo["status"] == "idle" and echo["pane"].startswith("t"), echo
        assert state.get("herdr") is True, "the core answered: the backend is up"
        print(f"ok   listed: {echo['pane']} kind={echo['kind']} status={echo['status']}, herdr absent")

        api(port, "/api/send", {"pane": echo["pane"], "text": "hello from reflexd", "label": "test"})
        until("the answer", lambda: "got:hello from reflexd" in (api(port, f"/api/pane?id={echo['pane']}&lines=20").get("text") or ""))
        print("ok   a prompt reached it and it answered")

        before = {a["pane"] for a in api(port, "/api/state")["agents"]}
        api(port, "/api/spawn", {"cwd": f"{work}/roots/proj", "kind": "pi", "text": ""})
        new = until("the new session", lambda: next((a for a in api(port, "/api/state")["agents"] if a["pane"] not in before), None), timeout=40)
        labels = json.loads(subprocess.run([HC, "get", "--json", new["pane"]], env=core_env, capture_output=True, text=True).stdout)["labels"]
        assert new["kind"] == "pi" and len(new["session"]) == 36 and labels.get("reflex.session") == new["session"], (new, labels)
        print(f"ok   started pi in {new['pane']} with session {new['session']}")

        api(port, "/api/close", {"pane": new["pane"]})
        until("it to end", lambda: all(a["pane"] != new["pane"] for a in api(port, "/api/state")["agents"]))
        print("ok   closed it")

        # What moving an agent from herdr does once herdr has closed it: the
        # same session, resumed in the core, in the same folder.
        api(port, "/api/resume", {"cwd": f"{work}/roots/proj", "kind": "pi", "session": new["session"], "mode": "resume", "text": "", "label": "move"})
        back = until("the resumed session", lambda: next((a for a in api(port, "/api/state")["agents"] if a["session"] == new["session"]), None), timeout=40)
        got = json.loads(subprocess.run([HC, "get", "--json", back["pane"]], env=core_env, capture_output=True, text=True).stdout)
        argv = " ".join(got.get("argv") or got.get("cmd") or [])
        assert back["pane"] != new["pane"] and ":" not in back["pane"] and got["labels"].get("reflex.session") == new["session"], (back, got["labels"])
        assert f"--session {new['session']}" in argv, argv
        print(f"ok   resumed that session in {back['pane']} (pi --session …)")
        api(port, "/api/close", {"pane": back["pane"]})
        until("it to end", lambda: all(a["pane"] != back["pane"] for a in api(port, "/api/state")["agents"]))
        print("reflexd on herdr-core: all checks passed")
    finally:
        if daemon:
            daemon.terminate()
            try:
                daemon.wait(timeout=5)
            except subprocess.TimeoutExpired:
                daemon.kill()
        subprocess.run([HC, "server", "stop"], env=core_env, capture_output=True, timeout=30)
        if os.environ.get("REFLEX_TEST_KEEP"):
            print("kept", work)
        else:
            shutil.rmtree(work, ignore_errors=True)
        shutil.rmtree(run_dir, ignore_errors=True)


def _try(fn):
    try:
        return fn()
    except Exception:
        return None


if __name__ == "__main__":
    main()
