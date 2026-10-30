#!/usr/bin/env python3
"""Test reflexd's herdr-core adapter (daemon/Hc.bend, daemon/Term.bend) against a real,
disposable core with fake agents: no live agent, no API calls, never your own core.

Needs Bend, a C compiler and hc (on PATH, or REFLEX_TEST_HC=/path/to/herdr-core).
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
HC = os.environ.get("REFLEX_TEST_HC") or shutil.which("hc") or shutil.which("herdr-core")

# Fake agents: `r <report>` sends an OSC 7501 status report, as an agent would.
R = r"""r(){ printf '\033]7501;%s\033\\' "$1"; }; """
AGENTS = {
    # Reports itself as Claude Code; its session comes from ~/.claude/sessions/<pid>.json.
    "claudeish": R + "r state=idle:app=claude-code; sleep 300",
    # pi-like and labelled with a session by Reflex: answers each line it reads.
    "echo": R + "r state=idle:app=pi; stty -echo; while read -r l; do r state=working; echo \"got:$l\"; r state=done; done",
    # Started by Reflex as Claude, not ready yet (it hasn't reported).
    "slow": "sleep 300",
    # Waiting on a question.
    "asks": R + "r state=blocked:kind=question:app=claude-code; sleep 300",
    # A turn that ended in an error.
    "broke": R + "r state=error:app=pi; sleep 300",
    # A plain program: not an agent.
    "plain": "sleep 300",
    # Started by Reflex as Claude, which has since quit to its shell: not an agent now.
    "quit": "exec sh -i",
}
LABELS = {"echo": ["reflex.session=s-echo"], "slow": ["reflex.kind=claude"], "quit": ["reflex.kind=claude"]}
NOT = ["agent plain ", "agent quit "]

EXPECT = [
    "t7 core=yes at=/core.sock bare=t7 on=t7",
    "box/t12 core=yes at=/core.sock bare=box/t12 on=box/t12",
    "wBE:p1 core=no at=/herdr.sock bare=wBE:p1 on=work/wBE:p1",
    "work/wBE:p1 core=no at=/m/work.sock bare=wBE:p1 on=work/work/wBE:p1",
    " core=no at=/herdr.sock bare= on=work/",
    "uuid 12345678-9abc-4ef0-8fff-ffff00000000",
    "agent claudeish kind=claude status=idle session=s-from-file",
    "agent echo kind=pi status=idle session=s-echo",
    "agent slow kind=claude status=unknown session=",
    "agent asks kind=claude status=blocked session=",
    "agent broke kind=pi status=done session=",
    "agent cx kind=codex status=unknown session=",
    "echo status idle",
    "prompt ok",
    "prompt before ready fail agent_not_ready: it has not said it is ready yet",
    "prompt while blocked fail blocked:",
    "echo answered yes",
    "keys ok yes",
    "run t",
    "run labels pi,sess-1 argv0=sh",
    "close ok",
    "closed status []",
    "up yes no",
]


def hc(env, *args, check=True):
    return subprocess.run([HC, *args], env=env, check=check, capture_output=True, text=True, timeout=30)


def main():
    if not HC:
        raise SystemExit("hc not found: install herdr-core or set REFLEX_TEST_HC")
    # The socket path must stay short; the state lives in a scratch folder.
    run_dir = tempfile.mkdtemp(prefix="rxc", dir="/tmp")
    work = tempfile.mkdtemp(prefix="reflex-core-test-")
    env = {**os.environ, "HC_SESSION": "rxtest", "XDG_RUNTIME_DIR": run_dir,
           "XDG_STATE_HOME": f"{work}/state", "XDG_CONFIG_HOME": f"{work}/config"}
    env.pop("HC_SOCKET", None)
    env.pop("HC_TERMINAL_ID", None)
    sock = f"{run_dir}/herdr-core/rxtest.sock"
    home = Path(work) / "home"
    try:
        started = time.monotonic()
        subprocess.run(["bend", "daemon/tests/core.bend", "-o", f"{work}/core"], cwd=ROOT, check=True,
                       timeout=300, capture_output=True, text=True,
                       env={**os.environ, "BEND_NO_TELEMETRY": "1"})
        built = time.monotonic()
        for name, script in AGENTS.items():
            labels = [x for l in LABELS.get(name, []) for x in ("--label", l)]
            hc(env, "run", "--bg", "--no-parent", "--name", name, *labels, "--", "sh", "-c", script)
        bin_dir = Path(work) / "bin"
        bin_dir.mkdir()
        # A program called codex that says nothing (a script would show its shell in front).
        (bin_dir / "codex").symlink_to("/bin/sleep")
        hc(env, "run", "--bg", "--no-parent", "--name", "cx", "--", str(bin_dir / "codex"), "300")
        time.sleep(1.5)
        # Claude names its session in ~/.claude/sessions/<pid>.json.
        got = json.loads(hc(env, "get", "--json", "claudeish").stdout)
        pid = got["foreground"]["pid"]
        (home / ".claude" / "sessions").mkdir(parents=True)
        (home / ".claude" / "sessions" / f"{pid}.json").write_text(json.dumps({"pid": pid, "sessionId": "s-from-file"}))
        run = subprocess.run([f"{work}/core"], cwd=ROOT, timeout=60, capture_output=True, text=True,
                             env={**os.environ, "REFLEX_TEST_CORE": sock, "REFLEX_TEST_HOME": str(home)})
        out = [l for l in run.stdout.splitlines() if l.strip()]
        missing = [e for e in EXPECT if not any(l.startswith(e) for l in out)]
        missing += [f"(not) {n}" for n in NOT if any(l.startswith(n) for l in out)]
        if run.returncode or missing:
            raise SystemExit("core adapter regression:\nmissing: " + "\n  ".join(missing) + "\n--- got:\n" + run.stdout + run.stderr)
        print(f"herdr-core adapter: {len(EXPECT) + len(NOT)} checks passed (build {built - started:.1f}s, run {time.monotonic() - built:.1f}s)")
    finally:
        hc(env, "server", "stop", check=False)
        shutil.rmtree(run_dir, ignore_errors=True)
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        raise SystemExit(f"{error.cmd}: {error.stdout}{error.stderr}") from error
