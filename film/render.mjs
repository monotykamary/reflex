// Render film/launch.html to an MP4, frame by frame, in headless Chrome.
//   node film/render.mjs [out.mp4] [--fps 30] [--at t1,t2,…  (stills only)]
// Every frame is film.render(t): the page is a pure function of time, so the
// render is exact and repeatable. Needs Google Chrome and ffmpeg.
import { spawn, execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const opt = (name, d) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : d; };
const out = args.find((a) => a.endsWith(".mp4")) ?? path.join(here, "reflex-launch.mp4");
const fps = +opt("--fps", 30);
const stills = opt("--at", null);
const chromeBin = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const profile = fs.mkdtempSync(path.join(os.tmpdir(), "reflex-film-"));
const frames = fs.mkdtempSync(path.join(os.tmpdir(), "reflex-frames-"));
const port = 9400 + Math.floor(Math.random() * 300);
const chrome = spawn(chromeBin, ["--headless=new", `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, "--hide-scrollbars",
  "--force-color-profile=srgb", "about:blank"], { stdio: "ignore" });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let ws;
for (let i = 0; i < 80 && !ws; i++) {
  try { const p = (await (await fetch(`http://127.0.0.1:${port}/json`)).json()).find((x) => x.type === "page"); if (p) ws = new WebSocket(p.webSocketDebuggerUrl); } catch {}
  await sleep(150);
}
if (ws.readyState !== WebSocket.OPEN) await new Promise((r) => ws.addEventListener("open", r));
let id = 0; const waits = new Map();
ws.addEventListener("message", (m) => { const d = JSON.parse(m.data); if (d.id && waits.has(d.id)) { waits.get(d.id)(d); waits.delete(d.id); } });
const call = (method, params = {}) => new Promise((r) => { const i = ++id; waits.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });

await call("Emulation.setDeviceMetricsOverride", { width: 1920, height: 1080, deviceScaleFactor: 1, mobile: false });
await call("Page.enable");
await call("Page.navigate", { url: "file://" + path.join(here, "launch.html") + "?still" });
await sleep(1200);
const length = (await call("Runtime.evaluate", { expression: "film.length", returnByValue: true })).result.result.value;

const times = stills ? stills.split(",").map(Number) : Array.from({ length: Math.round(length * fps) }, (_, i) => i / fps);
let n = 0;
for (const t of times) {
  await call("Runtime.evaluate", { expression: `film.render(${t})` });
  const shot = await call("Page.captureScreenshot", { format: stills ? "png" : "jpeg", quality: 94, captureBeyondViewport: false });
  const name = stills ? `still-${t}.png` : `f${String(n).padStart(5, "0")}.jpg`;
  fs.writeFileSync(path.join(stills ? path.dirname(out) : frames, name), Buffer.from(shot.result.data, "base64"));
  if (++n % 60 === 0) process.stdout.write(`\r${n}/${times.length} frames`);
}
ws.close();
chrome.kill();
await new Promise((r) => (chrome.exitCode !== null ? r() : chrome.once("exit", r)));
if (!stills) {
  execFileSync("ffmpeg", ["-loglevel", "error", "-y", "-framerate", String(fps), "-i", path.join(frames, "f%05d.jpg"),
    "-c:v", "libx264", "-preset", "slow", "-crf", "16", "-pix_fmt", "yuv420p", "-movflags", "+faststart", out]);
  console.log(`\nwrote ${out}`);
}
for (const dir of [frames, profile]) {
  try { fs.rmSync(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 }); } catch { /* the OS cleans tmp */ }
}
