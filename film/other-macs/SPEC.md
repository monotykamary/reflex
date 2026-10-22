# SPEC: "Every Mac. One rail." (Reflex 0.1.39 – 0.1.43)

GOAL:    a Reflex user on X gets it in one watch: the agent on my other Mac asks, I answer from this one,
         and the rail, ⌥⌥ bar and terminals hold both Macs' agents. They go to reflex.farm.
OUTPUT:  HyperFrames, 1920 x 1080, 30 fps, MP4 for X.
TIME:    40.8 s x 30 = 1224 frames. 100 BPM: a beat is 0.6 s (18 frames), a bar is 2.4 s (72 frames).
         The music is the launch film's score from its bar 7 (16.8 s) to its end, so film t = launch t − 16.8
         and every cue the launch score hits lands on this film's picture too (see CUES). Its break
         (bars 15–16, where the drums step back) plays twice: the second time, from 24.0, under @studio;
         everything after it lands 4.8 s later than in the launch score.
LOOK:    the launch film's: ground #08090c with a 0 → 4% lighter radial lift behind the hero, no grain;
         ink #ededef (62% / 36% for second and third ink); status colours only as the app uses them:
         the app's Tone: working #5C8CFF, waiting #FFB021, done #40D187, Jev #9E7AFF, remote #29B3C7.
         Accent: remote teal, rationed to the machine badge and chip, the Machines tile, the
         transition flood, and "Mac." on the claim.
         Display: SF Pro (SFNS) 700, −0.035em; claim lines 112 px, story lines 64 px, never two at once.
         Body / UI: SF Pro 21–30 px at 2x of the app's real size. Mono: Geist Mono (the app's
         terminal face) 25 px.
         Medium: the app's own panels, rebuilt from its SwiftUI at 1.6–2x: #18191e panels, 1 px
         rgba(255,255,255,.09) borders, 22–26 px radii, shadow 0 24 60 rgba(0,0,0,.5). No glass.
OBJECTS: - the edge tab at the screen's right edge: dots stacked, blue rings spin (linear, 1 turn / 0.9 s)
         - a remote agent's dot: wears the machine badge as the app draws it
         - the rail's question card (agent title, the question, numbered options 1 2 3)
         - Settings → Machines (host field, Test with its checks, Add)
         - the ⌥⌥ Ask bar (field, ranked rows with a weight each, Jev's pick)
         - a terminal window (traffic lights, header with the machine's name, the Shared state, Take Over)
         - the lazy-bot app icon (assets/icon.png), only on the end card
MOTION:  enter expo.out 0.5–0.7 s; travel / camera power4.inOut 0.6 s; exit power3.in 0.25–0.3 s;
         pops back.out(1.6) 0.35 s, on dots and chips only. Words of a line rise from a mask
         0.08 s apart (the launch film's entrance); lines leave by a 6 px blur-out in 0.2 s.
         Keys (⌥ ⌥, 1, ⏎) press down 4 px on their beat.
SHOTS:   (t in film seconds; scenes are sub-compositions)
  ask      0.0–9.6   HOOK + ANSWER. Edge tab (2.2x) on the right edge, blue rings spinning; line
                     "Your agent needs you." 1.2: amber dot pops, wearing the teal machine badge.
                     2.4: the question card slides out of the tab: "claude · pipeline", "Waiting for
                     your answer · pipeline on studio" (a teal band is drawn under "studio" at 3.0).
                     Line becomes "It's on your other Mac." 6.6: key 1 presses on the beat, option 1
                     lights; 7.2 the card folds into the tab, amber dot → blue ring. Line "Answer it
                     from here." 9.2: the teal badge grows past the frame (power3.in 0.4 s).
  machines 9.6–14.4  ADD A MAC. Teal flood irises down into the Machines tile of Settings (2x).
                     10.35 "studio" types into the host field; cursor clicks Test (10.5), "Testing…";
                     10.8 result: green check "Signed in, and herdr is there. Add it."; 11.4 Add,
                     "Adding…"; 12.0 the From herdr row lands "Connecting…", 12.6 "Connected · 3 agents".
                     Line "Add a Mac once." 14.1 the window blurs out.
  bar      14.4–17.4 SEND IT WORK. ⌥ 14.4, ⌥ 14.7; the bar drops in; "rerun the ingest tests" types;
                     15.6 Jev ranks: "Ingest pipeline fix" / "claude · pipeline on studio · working" on
                     top with the purple Jev chip and its weight; 16.2 ⌘⏎; 16.8 the row grows into the
                     terminal window. Line "Send it work."
  term     17.4–24.0 ITS TERMINAL. Header: glyph with badge, "claude · pipeline", studio chip,
                     "working · Ingest pipeline fix"; the Shared capsule with Take Over. Claude runs the
                     tests live. 20.1 punch-in on the header and Shared (line "Shared with the other
                     Mac."); 21.6 pull back; the prompt types "and commit it", ⏎ 23.0, Claude answers.
                     23.4 the window shrinks into its row of the agent list.
  scope    24.0–28.8 NAME A MAC. ⌥ ⌥, the bar; "@" lists your other Macs (0.9, the unsure note), "@s"
                     narrows to @studio, 2.1 ⏎ makes it the teal token; "ingest" finds studio's earlier
                     session (Resume) and folders, each wearing the studio chip; 3.6 ⏎ resumes it there.
                     Lines "Name a Mac." then "Search and resume there."
  rail     28.8–33.6 PAYOFF. The rail's agent list (2x): this Mac's agents, then studio's (26.4),
                     a needs-you one (27.3), mac-mini's (27.6), each with the teal chip.
                     Line "Wherever they run."
  claim    33.6–36.0 "Every Mac." on the 33.6 hit ("Mac." teal), "One rail." on 34.8. 112 px.
  end      36.0–40.8 The app icon drops in at 240 px, "reflex.farm" wipes in, "Reflex 0.1.43 · agents
                     on your other Macs", "Free and open source · for the Mac". Hold to 40.8.
CUES (film s): 1.2 1.8 2.4 · 6.0 6.6 7.2 · 10.8 11.4 12.0 · 15.6 16.2 16.8 · 20.1 20.7 21.3 21.6 ·
               24.0 26.4 27.3 27.6 · 28.8 30.0 31.2 · end 36.0
BANNED:  dark void with small floating UI (every UI shot fills ≥ 45% of the frame height);
         glow, particles, gradients beyond the one radial lift; three cards; slide-up fades on
         everything; titles moving after they land; a corner logo; any label the app doesn't show;
         a UI string not in the source.
QA:      frame 0 reads as a thumbnail (tab + "Your agent needs you."); 2.6 the card with the badge;
         7.3 answered; 12.2 tab full of badged dots; 16.9 the pick on top; 21.0 terminal header;
         26.5 the agent list; 30.2 claim; 34.0 end card.
