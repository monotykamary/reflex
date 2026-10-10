// The launch film's score: recorded instruments (CC0, see CREDITS.md),
// sequenced here on the film's clock (../grid.js) and mastered with ffmpeg.
// Nothing is synthesized but the room: a small reverb send.
//   node film/audio/fetch.mjs     # once: the recordings
//   node film/audio/score.mjs     # → film/audio/score.wav (48 kHz, −14 LUFS, −2.5 dBTP)
// Played by people, not a grid: every note off the cues drifts a few
// milliseconds and a fraction of a decibel (seeded, so every render is the
// same); the hits the picture lands on are sample-exact.
import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
await import(path.join(here, "..", "grid.js"));
const G = globalThis.GRID;
const SR = 48000;
const LEN = G.length;
const N = Math.ceil(LEN * SR);

// ── the recordings ──────────────────────────────────────────────────────────
const dir = path.join(here, "samples");
if (!fs.existsSync(path.join(dir, "index.json"))) { console.error("run node film/audio/fetch.mjs first"); process.exit(1); }
const cache = new Map();
function load(name) {
  if (cache.has(name)) return cache.get(name);
  const buf = execFileSync("ffmpeg", ["-v", "error", "-i", path.join(dir, name + ".wav"), "-f", "f32le", "-ac", "2", "-ar", String(SR), "-"], { maxBuffer: 1 << 30 });
  const x = new Float32Array(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.length));
  // Trim the silence before the attack, so a hit placed on a beat sounds on it.
  let on = 0;
  while (on < x.length && Math.abs(x[on]) < 0.002) on += 1;
  on = Math.max(0, (on >> 1) - 24) * 2;
  const s = { l: new Float32Array(x.length / 2 - on / 2), r: new Float32Array(x.length / 2 - on / 2) };
  for (let i = 0; i < s.l.length; i++) { s.l[i] = x[on + 2 * i]; s.r[i] = x[on + 2 * i + 1]; }
  cache.set(name, s);
  return s;
}

// Note names → MIDI. VCSL's piano and vibraphone and VSCO's bass name middle C
// "C3" (one octave below scientific); the TX81Z names it C4.
const PC = { C: 0, Cs: 1, D: 2, Ds: 3, E: 4, F: 5, Fs: 6, G: 7, Gs: 8, A: 9, As: 10, B: 11 };
const midiOf = (note, shift) => { const m = /^([A-G]s?)(\d)$/.exec(note); return 12 * (+m[2] + 1) + PC[m[1]] + shift; };
const names = JSON.parse(fs.readFileSync(path.join(dir, "index.json"), "utf8"));
function bank(prefix, shift, re) {
  const notes = [];
  for (const n of names) { const m = re.exec(n); if (m && n.startsWith(prefix)) notes.push({ name: n, note: m[1], midi: midiOf(m[1], shift), layer: m[2] }); }
  return notes;
}
const piano = bank("piano_", 12, /^piano_([A-G]s?\d)_v(\d)$/);
const bass = bank("bass_", 12, /^bass_([A-G]s?\d)_rr(\d)$/);
const vibes = bank("vibes_", 12, /^vibes_([A-G]s?\d)()$/);
const ep = bank("ep_", 0, /^ep_([A-G]s?\d)()$/);

// The nearest recording, re-pitched by varispeed (never more than a minor third).
function nearest(set, midi, layer) {
  let best = null;
  for (const s of set) {
    if (layer && s.layer && s.layer !== String(layer)) continue;
    if (!best || Math.abs(s.midi - midi) < Math.abs(best.midi - midi)) best = s;
  }
  return { name: best.name, rate: Math.pow(2, (midi - best.midi) / 12) };
}

// ── people, not a grid ──────────────────────────────────────────────────────
let seed = 0x5eed1234;
const rand = () => { seed |= 0; seed = (seed + 0x6d2b79f5) | 0; let t = Math.imul(seed ^ (seed >>> 15), 1 | seed); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
const gauss = () => { let u = 0; while (u === 0) u = rand(); return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * rand()); };
const human = () => Math.max(-0.012, Math.min(0.012, gauss() * 0.0065));
const db = (d) => Math.pow(10, d / 20);

// ── the mix: two stems and a send ───────────────────────────────────────────
const stems = { drums: [new Float32Array(N), new Float32Array(N)], music: [new Float32Array(N), new Float32Array(N)], send: [new Float32Array(N), new Float32Array(N)] };
const exact = []; // the sync hits, for the check at the end
const cueTimes = [G.bot, G.blink, G.folder, G.where, G.extremes, G.between, ...G.option, ...G.searches.flatMap((s) => [s.start, s.ranked, s.enter, s.arrive]),
  G.override.ranked, G.override.down, G.override.enter, G.override.arrive, G.reach, G.card, G.one, G.phone, G.say, G.finds, G.farm];
const onCue = (t) => Math.abs(t / G.bar - Math.round(t / G.bar)) * G.bar < 1e-6 || cueTimes.some((c) => Math.abs(c - t) < 1e-6);

/** Play one recording. at: seconds; gain: dB; pan −1…1; dur: seconds before a release (default: let it ring). */
function play(name, at, { gain = 0, pan = 0, rate = 1, dur = Infinity, release = 0.35, stem = "music", send = 0, sync = false } = {}) {
  const s = load(name);
  // The picture's cues and every downbeat are played dead on; the rest breathes.
  sync ||= onCue(at);
  if (!sync) { at += human(); gain += gauss() * 0.5; }
  else exact.push({ at, name });
  const g = db(gain), gl = g * Math.min(1, 1 - pan), gr = g * Math.min(1, 1 + pan);
  const start = Math.round(at * SR);
  const len = Math.min(Math.floor((s.l.length - 2) / rate), N - start, Number.isFinite(dur) ? Math.round((dur + release) * SR) : Infinity);
  const relStart = Number.isFinite(dur) ? Math.round(dur * SR) : Infinity, relLen = Math.max(1, Math.round(release * SR));
  const [ol, or] = stems[stem], [sl, sr] = stems.send;
  for (let i = 0; i < len; i++) {
    const p = i * rate, k = p | 0, f = p - k;
    let env = i < relStart ? 1 : Math.max(0, 1 - (i - relStart) / relLen);
    env *= env;
    const l = (s.l[k] + (s.l[k + 1] - s.l[k]) * f) * env, r = (s.r[k] + (s.r[k + 1] - s.r[k]) * f) * env;
    const j = start + i;
    if (j < 0) continue;
    ol[j] += l * gl; or[j] += r * gr;
    if (send) { sl[j] += l * gl * send; sr[j] += r * gr * send; }
  }
}

const rr = {};
const next = (key, n) => (rr[key] = ((rr[key] ?? -1) + 1) % n) + 1;
const B = G.beat, at = G.at;

// Instruments.
const kick = (t, loud = false, o = {}) => play(`kick_v${loud ? 5 : 3}_rr${next("kick", 2)}`, t, { gain: loud ? -1 : -3, stem: "drums", ...o });
const snare = (t, v = 7, o = {}) => play(`snare_v${v}_rr${next("snare" + v, 2)}`, t, { gain: -4, pan: -0.05, stem: "drums", send: 0.18, ...o });
const clap = (t, o = {}) => play(`clap_rr${next("clap", 3)}`, t, { gain: -9, pan: 0.05, stem: "drums", send: 0.22, ...o });
const hat = (t, v = 2, o = {}) => play(`hat_v${v}_rr${next("hat" + v, 2)}`, t, { gain: -15, pan: 0.32, stem: "drums", ...o });
const shake = (t, up, o = {}) => play(`shaker_Double_${up ? "Up" : "Down"}_rr${next("sh" + up, 2)}`, t, { gain: -21, pan: -0.38, stem: "drums", ...o });
const key = (t) => play(`hat_v1_rr${next("key", 2)}`, t, { gain: -17, pan: 0.1, stem: "drums", sync: true }); // a keystroke
const pianoNote = (midi, t, { v = 2, gain = -6, dur = Infinity, pan = 0, sync = false, release = 0.6 } = {}) => {
  const s = nearest(piano, midi, v);
  play(s.name, t, { rate: s.rate, gain, dur, pan, release, send: 0.32, sync });
};
const chord = (notes, t, o = {}) => notes.forEach((m, i) => pianoNote(m, t + (o.sync && i === 0 ? 0 : i * 0.006), { ...o, sync: o.sync && i === 0 }));
const pizz = (midi, t, o = {}) => { const s = nearest(bass, midi); play(s.name.replace(/rr\d/, `rr${next("bass", 2)}`), t, { rate: s.rate, gain: -2, dur: o.dur ?? 1.1, release: 0.25, send: 0.08, ...o }); };
const vibe = (midi, t, o = {}) => { const s = nearest(vibes, midi); play(s.name, t, { rate: s.rate, gain: -9, pan: -0.2, dur: o.dur ?? 2.2, release: 0.8, send: 0.42, ...o }); };
const epiano = (notes, t, o = {}) => notes.forEach((m) => { const s = nearest(ep, m); play(s.name, t, { rate: s.rate, gain: -16, pan: 0.15, dur: o.dur ?? G.bar, release: 0.5, send: 0.3, ...o }); });

// ── the harmony: A minor's warm loop, a question (Dm–E), home in C ──────────
const V = {
  Am: { root: 45, hand: [60, 64, 67, 71] }, F: { root: 41, hand: [57, 60, 64, 67] },
  C: { root: 48, hand: [55, 60, 62, 64] }, G: { root: 43, hand: [55, 59, 62, 64] },
  Dm: { root: 50, hand: [53, 57, 60, 64] }, E: { root: 40, hand: [56, 59, 62, 64] },
};
const changes = ["Am", "F", "C", "G", "Am", "F", "G", "Am", "F", "C", "G", "Am", "F", "C", "G", "Dm", "E", "Am", "F", "F", "C"];

// The sections, by bar.
const section = (b) => b < 2 ? "intro" : b < 4 ? "grow" : b < 5 ? "where" : b < 7 ? "half" : b < 15 ? "full" : b < 17 ? "break" : b < 19 ? "full" : b < 20 ? "end" : "tail";

for (let b = 0; b < 21; b++) {
  const t0 = at(b), sec = section(b), c = V[changes[b]];
  // Piano: the chord on 1, pushed on the "and" of 2 when the band plays.
  if (b === 19) { // "Say what." on F, "Reflex finds where." on G
    chord(V.F.hand, G.say, { v: 3, gain: -4, sync: true, dur: 1.15 });
    pianoNote(29, G.say, { v: 3, gain: -5, dur: 1.15 });
    chord(V.G.hand, G.finds, { v: 3, gain: -4, sync: true, dur: 1.3 });
    pianoNote(31, G.finds, { v: 3, gain: -5, dur: 1.3 });
  } else if (b === 20) { // home: C, open, ringing out
    chord([48, 55, 62, 64, 67, 72], G.farm, { v: 2, gain: -5, sync: true, dur: 4.5, release: 1.5 });
    pianoNote(36, G.farm, { v: 2, gain: -6, dur: 4.5, release: 1.5 });
  } else if (sec === "intro" || sec === "grow") {
    chord(c.hand, t0, { v: sec === "intro" ? 1 : 2, gain: -6, dur: G.bar * 0.98, sync: b === 0 });
    if (b === 0) pianoNote(c.root - 12, t0, { v: 1, gain: -9, dur: G.bar * 2 });
  } else {
    const push = sec === "full" || sec === "half";
    chord(c.hand, t0, { v: 2, gain: push ? -8 : -6, dur: push ? B * 1.4 : G.bar * 0.98, sync: b === 4 || b === 7 || b === 17 });
    if (push) chord(c.hand, t0 + B * 1.5, { v: 1, gain: -10, dur: B * 2.3 });
    if (sec === "where" || b === 17) pianoNote(c.root - 12, t0, { v: 3, gain: -5, dur: G.bar }); // the low strike under the hit
  }
  // The electric piano: a warm bed under the intro and the break.
  if (sec === "intro" || sec === "break") epiano(c.hand.map((m) => m - 12), t0, { dur: G.bar * 0.96 });

  // Bass, pizzicato: the root on 1, a walk into the next bar.
  if (sec !== "intro" && sec !== "tail" && b !== 19) {
    const nx = V[changes[b + 1]] ?? c;
    pizz(c.root - 12, t0, { sync: sec === "where" || b === 7 || b === 17 });
    if (sec === "full" || sec === "half") { pizz(c.root - 12, t0 + B * 1.5, { gain: -6 }); pizz(c.root, t0 + B * 2.5, { gain: -7, dur: 0.4 }); }
    pizz(nx.root - 12 + (nx.root > c.root ? -2 : 2), t0 + B * 3.5, { gain: -6, dur: 0.45 });
  }
  if (b === 19) { pizz(29, G.say, { sync: true }); pizz(31, G.finds, { sync: true }); }
  if (b === 20) pizz(36, G.farm, { dur: 4, release: 1.2, sync: true });

  // Drums.
  if (sec === "grow") for (let e = 0; e < 8; e++) shake(t0 + e * B / 2, e % 2 === 1, { gain: -24 + (b - 2) * 3 });
  if (sec === "where") {
    kick(t0, true, { sync: true }); clap(t0, { sync: true, gain: -6 }); snare(t0, 9, { gain: -6 });
    for (let e = 1; e < 8; e++) hat(t0 + e * B / 2, e % 2 ? 2 : 1, { gain: -18 });
    kick(t0 + B * 2.5);
  }
  if (sec === "half") {
    kick(t0); kick(t0 + B * 2.5, false, { gain: -6 }); snare(t0 + B * 2, 7);
    for (let e = 0; e < 8; e++) hat(t0 + e * B / 2, e % 2 ? 3 : 1);
    for (let e = 0; e < 16; e++) if (e % 4 === 2) shake(t0 + e * B / 4, e % 8 === 6);
  }
  if (sec === "full") {
    kick(t0, false, { sync: b === 7 || b === 17 }); kick(t0 + B * 1.75, false, { gain: -8 }); kick(t0 + B * 2.5, false, { gain: -5 });
    snare(t0 + B, 7); snare(t0 + B * 3, 7); clap(t0 + B); clap(t0 + B * 3);
    if (b % 2) snare(t0 + B * 3.75, 3, { gain: -14 });
    for (let e = 0; e < 8; e++) hat(t0 + e * B / 2, e % 2 ? 3 : 2, { gain: e % 2 ? -14 : -17 });
    for (let e = 0; e < 16; e++) shake(t0 + e * B / 4, e % 2 === 1, { gain: e % 4 === 0 ? -20 : -24 });
  }
  if (sec === "break") { // the drums step back while Jev isn't sure
    kick(t0, false, { gain: -6 });
    for (let e = 0; e < 8; e++) hat(t0 + e * B / 2, e % 2 ? 2 : 1, { gain: -18 });
    for (let e = 0; e < 16; e++) if (e % 2) shake(t0 + e * B / 4, e % 4 === 3, { gain: -25 });
  }
  if (sec === "end") {
    kick(G.say, true, { sync: true }); clap(G.say, { sync: true, gain: -6 }); snare(G.say, 9, { gain: -7 });
    kick(G.finds, true, { sync: true }); clap(G.finds, { sync: true, gain: -6 }); snare(G.finds, 9, { gain: -7 });
  }
}
// Fills: sixteenth snares rising into the hits.
const fill = (b, from) => { for (let e = from; e < 16; e++) snare(at(b) + e * B / 4, e < 12 ? 3 : 5, { gain: -18 + (e - from) * 1.1 }); };
fill(3, 8); fill(6, 12); fill(16, 12); fill(18, 12);

// The reflex motif on the vibraphone: a rising call in the intro; one note each
// time Jev answers, one each time the light lands; two lazy notes at the end.
vibe(81, at(0, 1.5), { gain: -10 }); vibe(84, at(0, 2.5), { gain: -11 }); vibe(88, at(0, 3), { gain: -10, dur: 3 });
vibe(86, at(1, 3), { gain: -11, sync: true }); vibe(84, at(1, 3.5), { gain: -12, dur: 3 }); // the blink
vibe(76, at(6, 3), { gain: -10, sync: true }); // "Reflex is in between."
const answer = [84, 81, 88, 86];
G.searches.forEach((s, i) => {
  vibe(answer[i], s.ranked, { sync: true, gain: -9, dur: 1.4 });
  vibe(answer[i] - 12 + 7, s.arrive, { sync: true, gain: -11, dur: 1.8 });
  key(s.enter);
});
key(G.option[0]); key(G.option[1]);
vibe(77, G.override.ranked, { sync: true, gain: -10, dur: 1.2 }); vibe(76, G.override.ranked + B / 2, { gain: -12, dur: 1.2 }); // unsure
key(G.override.down); key(G.override.enter);
vibe(81, G.override.arrive, { sync: true, gain: -9, dur: 2 });
key(G.one); vibe(84, G.one, { gain: -11, dur: 1.2 });
vibe(88, G.phone, { sync: true, gain: -11, dur: 1.6 });
vibe(88, at(20, 2), { gain: -12, dur: 3, release: 1.5 }); vibe(84, at(20, 3), { gain: -13, dur: 3, release: 1.5 });

// ── the room: a small hall on the send (Freeverb's structure) ───────────────
function reverb([il, ir], size = 0.84, damp = 0.35, pre = 0.022) {
  const scale = SR / 44100, combs = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617], alls = [556, 441, 341, 225];
  const outs = [];
  for (const [x, spread] of [[il, 0], [ir, 23]]) {
    const y = new Float32Array(N), d = Math.round(pre * SR);
    // A gentle high-pass into the room keeps the low end dry.
    let hp = 0, prev = 0; const a = Math.exp(-2 * Math.PI * 220 / SR);
    const inp = new Float32Array(N);
    for (let i = 0; i < N; i++) { const v = i >= d ? x[i - d] : 0; hp = a * (hp + v - prev); prev = v; inp[i] = hp * 0.015; }
    for (const c of combs) {
      const len = Math.round((c + spread) * scale), buf = new Float32Array(len); let k = 0, store = 0;
      for (let i = 0; i < N; i++) { const o = buf[k]; store = o * (1 - damp) + store * damp; buf[k] = inp[i] + store * size; y[i] += o; k = (k + 1) % len; }
    }
    for (const c of alls) {
      const len = Math.round((c + spread) * scale), buf = new Float32Array(len); let k = 0;
      for (let i = 0; i < N; i++) { const b = buf[k], o = -y[i] + b; buf[k] = y[i] + b * 0.5; y[i] = o; k = (k + 1) % len; }
    }
    outs.push(y);
  }
  return outs;
}
const [rl, rr2] = reverb(stems.send);
for (let i = 0; i < N; i++) { stems.music[0][i] += rl[i]; stems.music[1][i] += rr2[i]; }

// The tail breathes out; nothing ends on a cut.
const fadeFrom = Math.round((LEN - 2.2) * SR);
for (const s of [stems.drums, stems.music]) for (const ch of s) for (let i = fadeFrom; i < N; i++) ch[i] *= Math.pow(1 - (i - fadeFrom) / (N - fadeFrom), 2);

// ── master ──────────────────────────────────────────────────────────────────
function wav(file, [l, r]) {
  const b = Buffer.alloc(44 + N * 8);
  b.write("RIFF", 0); b.writeUInt32LE(36 + N * 8, 4); b.write("WAVEfmt ", 8); b.writeUInt32LE(16, 16); b.writeUInt16LE(3, 20); b.writeUInt16LE(2, 22);
  b.writeUInt32LE(SR, 24); b.writeUInt32LE(SR * 8, 28); b.writeUInt16LE(8, 32); b.writeUInt16LE(32, 34); b.write("data", 36); b.writeUInt32LE(N * 8, 40);
  for (let i = 0; i < N; i++) { b.writeFloatLE(l[i], 44 + i * 8); b.writeFloatLE(r[i], 48 + i * 8); }
  fs.writeFileSync(file, b);
}
// ffmpeg's measurements come on stderr.
const report = (args) => spawnSync("ffmpeg", ["-hide_banner", ...args, "-f", "null", "-"], { encoding: "utf8", maxBuffer: 1 << 26 }).stderr;
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "reflex-score-"));
wav(path.join(tmp, "drums.wav"), stems.drums);
wav(path.join(tmp, "music.wav"), stems.music);
// Drum bus glue (2.5:1), then the master EQ: HPF 26 Hz, +2.5 dB shelf at 90,
// −2 dB at 420, −2.5 dB shelf at 5.5 k, 24 dB/oct low-pass at 13 k.
const chain = "[0:a]acompressor=threshold=0.18:ratio=2.5:attack=12:release=160:makeup=1.3[d];" +
  "[1:a][d]amix=inputs=2:normalize=0,highpass=f=26:poles=2,bass=g=2.5:f=90:w=0.7,equalizer=f=420:t=q:w=1.0:g=-2," +
  "treble=g=-2.5:f=5500:w=0.7,lowpass=f=13000:poles=2,lowpass=f=13000:poles=2";
const pre = path.join(tmp, "pre.wav");
execFileSync("ffmpeg", ["-v", "error", "-y", "-i", path.join(tmp, "drums.wav"), "-i", path.join(tmp, "music.wav"), "-filter_complex", chain, "-c:a", "pcm_f32le", pre]);
// Loudness: gain to −14 LUFS, then an oversampled limiter (latency compensated)
// holds the drum tips under −2.5 dBTP; measure, correct the gain, once more.
const out = path.join(here, "score.wav");
const loud = (f) => { const r = report(["-i", f, "-af", "ebur128=peak=true"]); const s = r.slice(r.lastIndexOf("Summary:")); return { I: +/I:\s+(-?[\d.]+) LUFS/.exec(s)[1], TP: +/Peak:\s+(-?[\d.]+) dBFS/.exec(s)[1] }; };
let gain = -14 - loud(pre).I;
for (let pass = 0; pass < 3; pass++) {
  execFileSync("ffmpeg", ["-v", "error", "-y", "-i", pre, "-af",
    `volume=${gain.toFixed(2)}dB,aresample=192000,alimiter=limit=${db(-2.9).toFixed(4)}:attack=4:release=60:level=disabled:latency=1,aresample=${SR}`,
    "-c:a", "pcm_s24le", out]);
  const m = loud(out);
  if (Math.abs(m.I + 14) < 0.1) break;
  gain += -14 - m.I;
}

// ── check: loudness, and that mastering moved nothing in time ───────────────
// Every cue is placed on its exact sample, so the hits stay on the picture if
// the master adds no delay: cross-correlate it with the unmastered mix.
const { I, TP } = loud(out);
const mono = (f) => { const raw = execFileSync("ffmpeg", ["-v", "error", "-i", f, "-f", "f32le", "-ac", "1", "-ar", String(SR), "-"], { maxBuffer: 1 << 30 }); return new Float32Array(raw.buffer.slice(raw.byteOffset, raw.byteOffset + raw.length)); };
const dry = new Float32Array(N);
for (let i = 0; i < N; i++) dry[i] = stems.drums[0][i] + stems.drums[1][i] + stems.music[0][i] + stems.music[1][i];
const wet = mono(out);
let lag = 0, bestC = -Infinity;
for (let l = -480; l <= 480; l += 1) {
  let c = 0;
  for (let i = SR * 9; i < SR * 30; i += 3) c += dry[i] * (wet[i + l] ?? 0);
  if (c > bestC) { bestC = c; lag = l; }
}
fs.rmSync(tmp, { recursive: true, force: true });
console.log(`wrote ${path.relative(process.cwd(), out)} · ${LEN.toFixed(1)} s · ${I} LUFS · true peak ${TP} dBTP · ${exact.length} hits on their cues · master offset ${(lag / SR * 1000).toFixed(2)} ms`);
