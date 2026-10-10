# The launch film

"Say what. Reflex finds where." 52.8 s, 1920×1080, 60 fps. The film exists only as code.
Rendering it produces the video and its sound; neither goes into git.

```sh
node film/audio/fetch.mjs     # the score's recordings (CC0), into film/audio/samples/
node film/audio/score.mjs     # sequence and master → film/audio/score.wav
node film/render.mjs          # every frame → film/reflex-launch.mp4, with the score
```

- `grid.js` is the clock: 100 BPM, every scene on a bar, and the cues the picture and the music land on together.
- `launch.html` is the picture. Every frame is `film.render(t)`, a pure function of time.
  - Open it to watch it loop.
  - `?t=19.2` shows one moment.
  - `?play`, then a click, plays it with the rendered score.
  - The website plays it live with `?embed&loop=16.8,40.8`.
- `audio/score.mjs` is the music. It uses recorded drums, piano, upright bass and vibraphone; nothing is synthesized.
  - Timing is humanized off the cues.
  - Hits on the cues are sample-exact.
  - Mastered to −14 LUFS with a −2.5 dBTP ceiling.
  - `audio/CREDITS.md` lists every source.
- `render.mjs --at 5.6,19.2` writes stills instead of a video.

Needs Google Chrome, ffmpeg and Node 22 or later.
