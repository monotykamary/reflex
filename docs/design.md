# Design: Meniscus

Reflex's visual language treats the screen edge as a sliver of **liquid glass**
where your agents live as beads of light. Nothing drops from a notch and nothing
pops out of the middle of the screen: things *surface from the edge* and recede
back into it. It is built on macOS 26's Liquid Glass (`glassEffect`,
`GlassEffectContainer`, `glassEffectID`), so the chrome refracts what is behind
it and adjacent glass shapes merge like liquid.

## Surfaces

| Surface | What it is | Material |
|---|---|---|
| **Rail** | A glass tube on the right edge: inbox pill, one bead per agent, Ask. Hover (with 220 ms intent) widens it into right-aligned rows; labels emerge from behind the beads, clipped to the glass. | Glass |
| **Peek** | When an agent starts waiting, a bubble buds out of the tube beside its bead (the container merges the two shapes) with the question and keycaps. | Glass + thin material for text |
| **⌥⌥ bar** | A glass field and a glass tray beneath it. Agent chips (⇥) pin a target; the tray turns into the destination, the undo countdown, the choices or the error. | Glass |
| **Inbox** | Grows out of the rail (anchored trailing). Header is glass; cards are solid material. | Glass chrome, solid content |
| **Terminal** | A raw terminal (SwiftTerm running `herdr agent attach`) themed with any Ghostty theme — Tokyo Night by default — with a header in the theme's own colors. | Theme background |

**Glass is for controls, never for content.** Dense text (terminal output,
question bodies) sits on solid materials so it reads on any wallpaper; glass
over a busy backdrop is beautiful for a capsule and illegible for a paragraph.

## Beads

| State | Bead |
|---|---|
| working | blue, glowing, breathes (1.4 s ease-in-out) |
| blocked | amber with a ring |
| done | green, glowing |
| idle | grey |

A bead that just received a request bumps once (the only bounce in the app).

## Motion (after Emil Kowalski)

- **Frequency decides motion.** The ⌥⌥ bar opens instantly and J/K selection
  moves instantly: they happen hundreds of times a day. Motion is spent on
  outcomes — routing, the countdown, arrival — which you watch, not trigger.
- **Ease-out, short.** `enter` is ease-out-quint at 240 ms; `exit` is 160 ms;
  micro feedback 120 ms. Nothing in the chrome exceeds 300 ms.
- **Springs without bounce** for anything layout-shaped (rail width, card
  reflow), so motion is interruptible mid-flight.
- **Never from nothing.** Entrances start at scale 0.96–0.97 with a few points
  of offset and 3–4 px of blur, which hides the seam between states. Exits are
  quicker and quieter than entrances.
- **Origin-aware.** The inbox scales from its trailing edge (the rail); peeks
  bud from the bead that is waiting; rail labels slide out from the beads.
- **Honest time.** The undo window is a ring and a hairline that drain in real
  time; Esc reverses and returns your text. Pending dispatches poll faster so
  "sent" lands when it happens.
- **Feedback you can feel.** Buttons press to 0.97; picking a chip and a
  request arriving tick the trackpad haptics.
- **Reduced motion** keeps opacity changes and drops movement, blur and bounce.

Tokens live in `app/Sources/Reflex/Design.swift` (`Motion`, `Tone`, `Type`,
`Bead`, `KeyCap`, `CountdownRing`, `CountdownLine`, `ThinkingLine`, the
`surface`, `blurSwap` and `fromBead` transitions).

## The phone

The web remote (`web/index.html`) speaks the same language within the web's
means: frosted chrome (`backdrop-filter`), solid cards, beads with glow,
ease-out-quint at ≤ 250 ms, press feedback, only new elements animate,
draining undo lines, `prefers-reduced-motion`. Its pane viewer renders ANSI
color (16/256/truecolor, bold, dim, italic, underline, inverse) with the same
Tokyo Night family and a few other palettes, keeping the terminal's columns.
