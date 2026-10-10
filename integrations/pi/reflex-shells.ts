// installed by Reflex (Settings → Setup → pi background shells).
// Tells Reflex when pi-fabric's background shells still run after a turn has
// ended, so the session keeps counting as working (pi wakes when they finish)
// instead of looking done. While any run, this writes
//   ~/.pi/agent/reflex/sessions/<pid>.json  {pid, sessionId, status: "shell", running}
// and removes it when none do, or when pi exits. It only listens to
// pi-fabric's public "pi-fabric:shell:timing:v1" event (no command, output or
// path is in it) and changes nothing in pi. Delete this file to turn it off.
// @ts-nocheck
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const EVENT = "pi-fabric:shell:timing:v1";
const dir = path.join(os.homedir(), ".pi", "agent", "reflex", "sessions");
const file = path.join(dir, `${process.pid}.json`);

export default function reflexShells(pi) {
  let sessionId;
  const running = new Map(); // taskId → owning session

  function write() {
    try {
      const owner = sessionId ?? [...running.values()][0];
      const mine = [...running.values()].filter((s) => s === owner).length;
      if (mine === 0) {
        fs.rmSync(file, { force: true });
        return;
      }
      fs.mkdirSync(dir, { recursive: true });
      const tmp = `${file}.tmp`;
      fs.writeFileSync(tmp, JSON.stringify({ pid: process.pid, sessionId: owner, status: "shell", running: mine, updatedAt: Date.now() }));
      fs.renameSync(tmp, file);
    } catch {
      // Reporting must never break pi.
    }
  }

  function remember(ctx) {
    try {
      const id = ctx?.sessionManager?.getSessionId?.();
      if (typeof id === "string" && id.length > 0) sessionId = id;
    } catch {}
  }

  pi.on("session_start", (_event, ctx) => {
    remember(ctx);
    running.clear();
    write();
  });
  pi.on("agent_start", (_event, ctx) => remember(ctx));

  pi.events.on(EVENT, (e) => {
    if (!e || e.version !== 1 || typeof e.taskId !== "string") return;
    if (e.phase === "started") running.set(e.taskId, e.sessionId);
    else running.delete(e.taskId);
    write();
  });

  process.once("exit", () => {
    try {
      fs.rmSync(file, { force: true });
    } catch {}
  });
}
