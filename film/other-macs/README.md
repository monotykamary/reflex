# Update film: agents on your other Macs (0.1.39 – 0.1.43)

"Every Mac. One rail." 40.8 s, 1920×1080, 30 fps, for X. A HyperFrames project: `SPEC.md` is the brief, `STORYLINES.md` the two cuts not taken, `REVIEW.md` the last review.

It runs on the launch film's clock and music: the score from its bar 7 (16.8 s) to the end, with its break (bars 15–16) played twice for the @studio scene, so the picture lands on the same hits.

```sh
node film/audio/fetch.mjs && node film/audio/score.mjs     # the launch score, once
ffmpeg -i film/audio/score.wav -filter_complex "[0]atrim=16.8:40.81,asetpts=PTS-STARTPTS[a];[0]atrim=36.0:52.8,asetpts=PTS-STARTPTS[b];[a][b]acrossfade=d=0.01:c1=tri:c2=tri,afade=t=in:d=0.03[o]" -map "[o]" -ar 48000 film/other-macs/assets/score.wav
mkdir -p film/other-macs/assets/fonts
cp build/AppIcon-1024.png film/other-macs/assets/icon.png       # drawn by scripts/build-app.sh
cp /System/Library/Fonts/SFNS.ttf /System/Library/Fonts/SFNSMono.ttf film/other-macs/assets/fonts/   # SF Pro and SF Mono; not redistributable
cp ~/Library/Fonts/"GeistMono[wght].ttf" film/other-macs/assets/fonts/GeistMono.ttf   # Geist Mono (OFL), the app's terminal face
cd film/other-macs && npx hyperframes render -q delivery -o renders/reflex-0.1.43-other-macs.mp4
```

Only text is in git: `assets/` (the score cut, the icon, the fonts) is made by the commands above. `npx hyperframes preview` opens it in Studio. Every UI string is the app's own: Settings → Machines, the question card, the ⌥⌥ bar row, the terminal header and Shared capsule (see `app/Sources/Reflex/`).
