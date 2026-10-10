// Fetch the score's recordings: every one CC0 (public domain), from the
// Versilian Community Sample Library and VSCO 2 Community Edition on GitHub.
// They land in film/audio/samples/ (not committed); CREDITS.md lists them.
//   node film/audio/fetch.mjs
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const out = path.join(here, "samples");
const VCSL = "https://raw.githubusercontent.com/sgossner/VCSL/master/";
const VSCO = "https://raw.githubusercontent.com/sgossner/VSCO-2-CE/master/";

// name → [library, path]
const files = {};
const add = (name, lib, p) => { files[name] = [lib, p]; };

// Grand piano (Kawai), sustains: notes C, D#, F#, A across octaves 1–6, velocity layers v1–v3.
// (VCSL samples C and F# in every octave; D# and A only at the ends.)
for (const oct of [1, 2, 3, 4, 5, 6]) for (const n of ["C", "D#", "F#", "A"]) for (const v of [1, 2, 3]) {
  if ((n === "D#" || n === "A") && oct > 1 && oct < 5 || n === "F#" && oct === 6 && v < 3) continue;
  add(`piano_${n}${oct}_v${v}`, VCSL, `Chordophones/Zithers/Grand Piano, Kawai/Sustains/GPiano_sus_${n}${oct}_v${v}_rr1_Player.wav`);
}
// Upright bass, pizzicato: E, G, A#, C#, F# low octaves, two takes.
for (const note of ["E0", "G0", "A#0", "C1", "D1", "E1", "F#1", "G#1", "A1", "C#2", "E2", "G#2", "B2"]) for (const rr of [1, 2]) {
  add(`bass_${note}_rr${rr}`, VSCO, `Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_${note}_v1_rr${rr}.wav`);
}
// Drums.
for (const v of [3, 5]) for (const rr of [1, 2]) add(`kick_v${v}_rr${rr}`, VCSL, `Membranophones/Struck Membranophones/Bass Drum 1/BDrumNew_hit_v${v}_rr${rr}_Sum.wav`);
for (const v of [3, 5, 7, 9]) for (const rr of [1, 2]) add(`snare_v${v}_rr${rr}`, VCSL, `Membranophones/Struck Membranophones/Snare Drum, Modern 1/Snare2_HitSN_v${v}_rr${rr}_Mid.wav`);
for (const v of [1, 2, 3, 4]) for (const rr of [1, 2]) add(`hat_v${v}_rr${rr}`, VCSL, `Idiophones/Struck Idiophones/Hi-Hat Cymbal/HiHat_HitC_v${v}_rr${rr}_Mid.wav`);
for (const rr of [1, 2, 3]) add(`clap_rr${rr}`, VCSL, `Idiophones/Struck Idiophones/Claps/Clap_rr${rr}.wav`);
for (const k of ["Double_Down", "Double_Up"]) for (const rr of [1, 2]) add(`shaker_${k}_rr${rr}`, VCSL, `Idiophones/Struck Idiophones/Shaker, Small/Mid_Shaker${k}_rr${rr}.wav`);
for (const rr of [1, 2]) add(`shaker_slap_rr${rr}`, VCSL, `Idiophones/Struck Idiophones/Shaker, Small/Mid_Shaker_Slap_rr${rr}.wav`);
add("shaker_roll_rr1", VCSL, "Idiophones/Struck Idiophones/Shaker, Small/Mid_Shaker_Roll_Fast_rr1.wav");
// Soft-mallet vibraphone: the "reflex" motif.
for (const n of ["C3", "E3", "G3", "B3", "D4", "F4", "A4", "C5", "E5"]) add(`vibes_${n}`, VCSL, `Idiophones/Struck Idiophones/Vibraphone/Soft Mallets/Vibes_soft_${n}_v2_rr1_Main.wav`);
// FM electric piano (TX81Z): the intro's warmth.
for (const n of ["C", "E", "G#"]) for (const oct of [2, 3, 4, 5]) add(`ep_${n}${oct}`, VCSL, `Electrophones/TX81Z/FM Piano/FMPiano_${n}${oct}_vl1.wav`);

fs.mkdirSync(out, { recursive: true });
let fetched = 0, kept = 0, missing = [];
for (const [name, [lib, p]] of Object.entries(files)) {
  const dest = path.join(out, name.replace(/#/g, "s") + ".wav");
  if (fs.existsSync(dest)) { kept++; continue; }
  const url = lib + p.split("/").map(encodeURIComponent).join("/");
  const r = await fetch(url);
  if (!r.ok) { missing.push(`${name} (${r.status})`); continue; }
  fs.writeFileSync(dest, Buffer.from(await r.arrayBuffer()));
  fetched++;
}
fs.writeFileSync(path.join(out, "index.json"), JSON.stringify(
  Object.keys(files).filter((n) => fs.existsSync(path.join(out, n.replace(/#/g, "s") + ".wav"))).map((n) => n.replace(/#/g, "s")), null, 0));
console.log(`fetched ${fetched}, already had ${kept}${missing.length ? `, missing: ${missing.join(", ")}` : ""}`);
