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

# What a core restart leaves, and what Reflex shows of it as stopped (/api/stopped).
LOST = {
    # Kept, an agent running: Reflex marks its shell; the restart gives it another one.
    "kept": (["--keep", "--label", "reflex.kind=pi", "--label", "reflex.session=s-kept"], R + "r state=idle:app=pi; sleep 300"),
    # Kept, its agent quit to the same shell (marked earlier): the mark goes, it's a shell.
    "keptquit": (["--keep", "--label", "reflex.kind=claude"], "exec sh -i"),
    # Not kept: the restart ends it.
    "lost": (["--label", "reflex.kind=claude", "--label", "reflex.session=s-lost"], "sleep 300"),
    # Brought back since, by name or by session: not shown twice.
    "dup": (["--label", "reflex.kind=pi"], "sleep 300"),
    "bysession": (["--label", "reflex.kind=claude", "--label", "reflex.session=s-carried"], "sleep 300"),
    # Ended on purpose: an exit, a kill.
    "ended": (["--label", "reflex.kind=pi"], "exit 0"),
    "killed": (["--label", "reflex.kind=pi"], "sleep 300"),
}
SHOWN = {"kept": ("pi", "s-kept", {"restart"}), "lost": ("claude", "s-lost", {"stopped_by_restart", "server_stop"})}
HIDDEN = ["keptquit", "dup", "bysession", "ended", "killed", "plain"]

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
        for name, (flags, script) in LOST.items():
            hc(env, "run", "--bg", "--no-parent", "--name", name, *flags, "--", "sh", "-c", script)
        time.sleep(1.5)
        hc(env, "kill", "killed")
        quit_pid = json.loads(hc(env, "get", "--json", "keptquit").stdout)["pid"]
        hc(env, "label", "keptquit", f"reflex.shell={quit_pid}")
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
        # The poll marked the kept agent's shell and unmarked the one whose agent quit.
        kept = json.loads(hc(env, "get", "--json", "kept").stdout)
        quit = json.loads(hc(env, "get", "--json", "keptquit").stdout)
        if kept["labels"].get("reflex.shell") != str(kept["pid"]) or quit["labels"].get("reflex.shell", ""):
            raise SystemExit(f"shell marks: kept {kept['labels']} pid {kept['pid']}, keptquit {quit['labels']}")
        # A stop ends the programs (a restart alone keeps them in the holder); the
        # next start gives kept terminals a shell.
        hc(env, "server", "stop")
        hc(env, "server", "start")
        time.sleep(3)
        again = json.loads(hc(env, "get", "--json", "kept").stdout)
        if again["state"] != "live" or again["pid"] == kept["pid"]:
            raise SystemExit(f"the restart didn't give kept a new shell: {again['state']} pid {again['pid']}")
        hc(env, "run", "--bg", "--no-parent", "--name", "dup", "--", "sleep", "300")
        hc(env, "run", "--bg", "--no-parent", "--name", "carrier", "--label", "reflex.session=s-carried", "--", "sleep", "300")
        after = subprocess.run([f"{work}/core"], cwd=ROOT, timeout=60, capture_output=True, text=True,
                               env={**os.environ, "REFLEX_TEST_CORE": sock, "REFLEX_TEST_HOME": str(home), "REFLEX_TEST_PHASE": "after"})
        line = next((l for l in after.stdout.splitlines() if l.startswith("stopped-json ")), "")
        if after.returncode or not line:
            raise SystemExit("no stopped list after the restart:\n" + after.stdout + after.stderr)
        got = json.loads(line[len("stopped-json "):])
        names = {x["name"]: x for x in got["stopped"]}
        bad = [f"{n}: missing" for n in SHOWN if n not in names]
        bad += [f"{n}: {names[n]['kind']} {names[n]['session']} {names[n]['why']}" for n, (k, sess, why) in SHOWN.items()
                if n in names and (names[n]["kind"] != k or names[n]["session"] != sess or names[n]["why"] not in why)]
        bad += [f"{n}: shown, shouldn't be" for n in HIDDEN if n in names]
        if not got["ok"] or bad:
            raise SystemExit("stopped agents:\n  " + "\n  ".join(bad) + "\n--- got:\n" + json.dumps(got, indent=1))
        print(f"herdr-core adapter: {len(EXPECT) + len(NOT) + 2 + len(SHOWN) + len(HIDDEN)} checks passed (build {built - started:.1f}s, run {time.monotonic() - built:.1f}s)")
    finally:
        hc(env, "server", "stop", check=False)
        shutil.rmtree(run_dir, ignore_errors=True)
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        raise SystemExit(f"{error.cmd}: {error.stdout}{error.stderr}") from error
