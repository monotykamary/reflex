# Review: render 2 (renders/reflex-0.1.42-other-macs.mp4)

## Render 2: the person's notes
- Take Over: the cursor presses it at 21.3 s. The Shared capsule goes, and the header's hand-over button (rectangle.on.rectangle) appears, as in `AgentPopout.swift`.
- "Testing…" and "Adding…" now replace the label inside the button, and the button widens.
- Settings → Machines was rebuilt from a screenshot of the app, positions in pt:
  - sidebar with search, the Reflex row (its count goes from 4 to 7 agents in herdr as studio connects), coloured tiles, and the blue selection
  - the back/forward capsule and the title
  - the header card, with the bold section headers "From herdr" and "Add a Mac"
  - the footer under the herdr list
  - the divider above the host field
  - SF Mono for code
- The question card slides out from behind the tab under a clip-path. Its text is no longer squeezed by scaleX.

# Render 1

## Creative calls
- Storyline A, "Two desks, one rail", was picked. Not built: B (the launch film's folder tree grows a second root) and C (the setup checks flip red to green on the beat).
- The music is the second half of the launch film's score, not a new track. The cuts and hits land on its cues: 1.2 / 2.4 vibes, 6.6 key for "1", 28.8 and 30.0 for the claim, 31.2 the last chord for the end card.
- The UI was rebuilt from the Swift source at 2 to 2.5× its pt size:
  - colours come from `Tone`
  - strings are verbatim
  - icons are drawn after SF Symbols
- These are illustrative, not real data:
  - the machine names `studio` and `mac-mini`
  - the agent names
  - the Jev weights (91 / 4 / 3 / 2 %)
  - the test output
- Accent is the app's remote teal: the badge, the chip, the Machines tile, the flood into Settings, and "Mac." on the claim.

## Measured vs. looked at
- `check` passes with 0 errors.
- Looked at: snapshot review sheets (every scene, every seam, phone width), plus four frames pulled from the rendered MP4.
- Sound was measured, not heard: AAC 48 kHz stereo at −14.2 LUFS integrated. That matches the launch score's master.

## Warnings kept on purpose
- `text_below_floor` on secondary UI text: chip labels, subtitles and step details at about 20 to 24 px. They're the app's real proportions. The words that carry the story (lines, card question, typed host, bar row title, Shared / Take Over) are 26 px or larger, or punched in on.
- `line_unread` on UI text that is replaced in place, for example "Testing…" → result, and "Connecting…" → "Connected · 3 agents". These are state changes, not lines to read.
- Contrast on the host field's placeholder: it matches the app.

## Weakest shots / with more time
- 14.4–14.8: the gap between the Machines window leaving and ⌥ ⌥ landing is nearly empty. The ⌥ keys could start bigger, or the bar could drop over the blurring window.
- 24.0: one dark frame between the terminal and the agent list. A true carry (the window shrinking into its row) would read better than the blur-out.
- The flood into Settings: the iris circle reads as a teal dot over the window for about 0.3 s.
