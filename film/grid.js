// The film's clock, shared by the picture (launch.html) and the score
// (audio/score.mjs): 100 BPM in 4/4, so a beat is 0.6 s and a bar 2.4 s. Every
// scene starts on a bar, and every cue below is a moment both the music and the
// picture land on together. at(bar, beat) — bar from 0, beat from 1 (halves ok).
(function (g) {
  const bpm = 100, beat = 60 / bpm, bar = beat * 4;
  const at = (b, n = 1) => +(b * bar + (n - 1) * beat).toFixed(4);

  // The four requests (bars 7–14, two bars each) and the override (15–16) share
  // one shape: type on 1, Jev ranks on 3, ⏎ on 4, the light reaches its folder
  // on the next bar's 1, where the caption holds.
  const search = (b) => ({ start: at(b), typed: at(b, 2.25), ranked: at(b, 3), enter: at(b, 4), arrive: at(b + 1), out: at(b + 1, 4.5) });
  const override = { start: at(15), typed: at(15, 2), ranked: at(15, 2.5), down: at(15, 3.5), enter: at(15, 4.5), arrive: at(16), out: at(16, 4.5) };

  g.GRID = {
    bpm, beat, bar, at,
    bot: at(0),                     // the lazy bot, alone
    blink: at(1, 3),
    folder: at(2),                  // "Every agent starts in a folder." — the tree grows
    where: at(4),                   // "Where?" — the first hit
    extremes: at(5),                // choose it yourself, or have it hidden
    between: at(6, 3),              // "Reflex is in between."
    option: [at(6, 4), at(6, 4.5)], // ⌥ ⌥
    searches: [7, 9, 11, 13].map(search),
    override,
    reach: at(17),                  // the tree takes flight into the edge
    card: at(18),
    one: at(18, 2.5),
    phone: at(18, 3),
    say: at(19),                    // "Say what."
    finds: at(19, 3),               // "Reflex finds where."
    farm: at(20),                   // reflex.farm
    length: at(22),               // reflex.farm holds while the last chord rings out
  };
})(globalThis);
