# Reflex

One place to see, answer and talk to every coding agent you run in
[herdr](https://herdr.dev) — routed by a **System 1** model instead of a chat
agent.

Reflex is a Mac menu-bar app in the spirit of [One](https://getone.one), with
two deliberate differences:

- **Terminal-native, subscription-native.** Your agents (Claude Code, Codex, pi,
  Grok, …) keep running in their own TUIs inside herdr, on the plans you
  already pay for. Reflex never wraps them in an SDK, ACP or a chat API.
- **System 1 routing.** No LLM sits at the helm rewriting your words. A request
  goes to [Jev](https://typesafe.ai/blog/introducing-system-one-models-and-jev)
  (via [jev-fabric](https://github.com/fabric-runtime/jev-fabric)) as typed
  questions over candidates Reflex built itself — *which live session? which
  folder? is this a side question?* — and comes back as keys and
  probabilities in a few hundred milliseconds. Your text is delivered verbatim.

The routing and dispatch core is written in [Bend](https://bend-lang.com) and
its safety rules are stated as laws and machine-checked (`daemon/LAWS.bend`).

```text
 Reflex.app (Swift)                         phone (web remote)
 edge strip · ⌥⌥ bar · inbox · popouts      same API, token in the QR link
          │  HTTP + bearer token                 │
          └──────────────┬───────────────────────┘
                 reflexd (Bend, native)
     actor ── Core.step(State, Msg) → (State, dispatches)   ← pure, proven
       │ ticker · poller · indexer · http · exec
       ├── herdr socket (agents, screens, prompt, keys, workspaces)
       ├── jev-fabric serve (one typed Jev call per request)
       └── reflex-scan.sh / reflex-fork.sh (folder facts, /btw forks)
```

## What it does

| | |
|---|---|
| **Tab & rail** | While agents are active, a small dark tab grows out of the right screen edge: a spinning ring per working agent, amber for waiting, green for done. Hover it (or rest on an empty edge for half a second) to open the rail, in Liquid Glass: inbox, agents, Ask and Settings, beside the question waiting on you (answer with 1, 2 or 3). Hover a dot for its state; click the dots for every agent, grouped by project, with one click to its terminal, a pinned message, or herdr. |
| **⌥⌥ Ask bar** | Double-tap Option and type. Like Dia, it tells a lookup from a request: a few words search your sessions, most recently switched first like ⌘Tab (⏎ opens that terminal, no Jev call; ⌘⌫ twice closes the session), with an "Ask" row to route them anyway (⌘⏎); prose — four or more words, a sentence, or a phrase starting like an instruction or question — becomes a Raycast-style list of where it could go — live sessions, folders to start one in, a new folder, any folder you choose. A local match fills it at once; Jev's live ranking (about a second after you stop typing) puts its pick on top with a weight per row. ⏎ sends to the selected row (submitted, as if typed and entered; the terminal stays closed); ⌘⏎ sends and opens that terminal; ↑↓/⇥ choose another, ⌘1–9 sends a row directly. Hovering never selects, a click on a row that just moved is ignored, and once you pick a row Jev stops moving it. `/claude`, `/pi`, `/codex`… choose the agent for new sessions; `/new` starts in a new folder; `/btw` asks on the side; `/folder` chooses any folder (one outside your roots joins your projects). A new folder is Jev's pick only when you say your keyword ("new project" by default) or nothing fits — and ⏎ asks you to name it first. Sends go at once. |
| **Unsure? It asks.** | Below the confidence threshold (default 60%) nothing is sent: you get numbered choices (1/2/3) instead. |
| **Resume** | Earlier sessions come back into herdr. Reflex reads Claude's, pi's and Codex's own session files (title, folder, last prompt) and Claude's background sessions (`claude agents --json`), leaving out what is already live. Search finds them under live sessions; `/resume` lists only them; ⏎ resumes (attaches a running `claude --bg`, forks one open in another terminal), ⌘⏎ forks. Jev is offered the most relevant few: "continue the logo work" resumes that conversation and sends the request there — only when Jev is sure, and never over a live session (both proved). The rail lists background sessions. |
| **Inbox** | Every blocked question (with its numbered options parsed off the agent's screen), finished turn, side answer and routing question. J/K move, 1–9 answer, E clear, ⏎ open. |
| **btw** | Start with `btw` (or let Jev notice) to ask without interrupting: Claude Code gets its native `/btw` (no tools, shares the prompt cache); pi — and Claude when blocked on a dialog — gets a headless, unsaved fork of its session (same prefix, warm cache, read-only for Claude). Other harnesses: Reflex asks you. |
| **Terminals** | Click a bead for a raw terminal on that agent (SwiftTerm attached through `herdr agent attach`): full color, keys and resizing go straight to the agent's TUI. Any Ghostty theme, Tokyo Night by default; Geist Mono when installed, or any monospaced font (Settings → Terminal). |
| **Phone** | Settings → Phone shows a QR code for the web remote (prefers your Tailscale address). |

Deliberately out of scope: voice input, and drag-to-point screenshots.

The design language ("Meniscus": liquid glass at the screen edge, motion after
Emil Kowalski's principles) is described in `docs/design.md`.

## How routing works

1. **Candidates are built deterministically.** Live agents come from herdr
   (kind, folder, state, title, last lines of output). Folders come from the
   index (`scripts/reflex-scan.sh`: every git repo under your roots with its
   description, recent commit subjects, branch, activity age and how often you
   started sessions there), ranked by `daemon/Index.bend`: folders you name
   are pinned first, then lexical matches, then recent activity. At most 8
   folders and 12 agents are offered.
2. **One Jev call, three typed questions:** `target` (choice over `a0…aN`,
   `new`), `folder` (choice over `f0…fN`), `side` (noul).
3. **Typed answer → decision** (`daemon/Route.bend`): every key maps back to a
   candidate, or the request becomes an inbox question. The harness for a new
   session is the one you name in the text (`codex`, `claude`, `pi`, …),
   otherwise your default.

Try it without sending anything: `POST /api/route {"text": "...", "dry": true}`
returns the decision; `POST /api/explain` returns the exact Jev request.

## Laws

`bend daemon/PROOF.bend` checks every law in `daemon/LAWS.bend`
(`ALL PROOFS CHECK`):

- `fired_are_ripe`, `kept_are_unripe`, `fire_partitions` — the undo window
  releases exactly the dispatches whose deadline passed; nothing is lost or
  duplicated.
- `cancel_removes` — undo works: a cancelled dispatch can never run.
- `tick_runs_ripe`, `tick_keeps_unripe`, `enqueue_runs_nothing`,
  `answer_runs_nothing` — only the clock runs anything, and it runs exactly
  what `fire` released.
- `new_blocked_agent_asks`, `finished_turn_reports`, `answered_question_clears`
  — inbox transitions.
- `unsure_target_never_acts`, `unsure_folder_never_acts` — below the threshold
  Reflex asks, it never acts.
- `blocked_agent_gets_no_native_btw` — a side question never types into a
  blocked agent's TUI, for any harness.
- `rank_is_bounded` — Jev is offered at most k folders.

The laws cover reflexd's policy. herdr, Jev, the harnesses and the Bend
runtime are assumptions. `bend daemon/PROOF.bend --verdict` re-checks with
Bend's Lean-proven kernel (needs Lean v4.34.0).

## Build and run

Requirements: macOS 26+ (Liquid Glass), Bend 2.0.36 (`curl -fsSL https://bend-lang.com/install.sh | sh`),
Xcode/Swift 6, [herdr](https://herdr.dev) 0.9+, jev-fabric
(`curl -fsSL https://raw.githubusercontent.com/fabric-runtime/jev-fabric/main/install.sh | sh`)
and a Jev provider key (TypeSafe by default).

```sh
scripts/build-app.sh          # reflexd + Reflex.app → build/Reflex.app
open build/Reflex.app
```

First run opens a short welcome: it checks herdr and its integrations,
connects Jev (one click to reuse pi's TypeSafe key, or paste a key) and lets
you try a real request as a dry run, indexes your project roots, has you try
⌥⌥ and the edge gesture, and ends with your Reflex card. Every check also
lives in Settings → Setup, live, with the welcome one click away.
For `btw` forks to target the exact session, install herdr's integrations:
`herdr integration install claude && herdr integration install pi`
(without them Reflex forks the newest session in that folder).

### Daemon only

```sh
scripts/build-app.sh --daemon
REFLEX_TOKEN=dev REFLEX_SCAN=$PWD/scripts/reflex-scan.sh REFLEX_FORK=$PWD/scripts/reflex-fork.sh \
  REFLEX_WEB=$PWD/web JEV_PROVIDER=typesafe TYPESAFE_API_KEY=... build/reflexd
curl -H 'authorization: Bearer dev' localhost:47823/api/state
```

| Variable | Default | |
|---|---|---|
| `REFLEX_PORT` / `REFLEX_BIND` | `47823` / `127.0.0.1` | `0.0.0.0` for the phone remote |
| `REFLEX_TOKEN` | generated (printed once) | bearer token for every `/api/*` call |
| `REFLEX_HERDR_SOCKET` / `HERDR_SESSION` | default herdr session | |
| `REFLEX_HARNESS` | `claude` | agent for new sessions |
| `REFLEX_THRESHOLD` | `6000` | confidence (basis points) needed to act |
| `REFLEX_UNDO_MS` | `0` | delay before an action runs (the app sends at once) |
| `REFLEX_FOLDERS_FILE` | — | file of extra folders to index, one per line (folders added from the Ask bar) |
| `REFLEX_ROOTS` | `~/VCS` | colon-separated roots for the folder index |
| `REFLEX_JEV` | `jev-fabric` | jev-fabric binary |
| `REFLEX_DATA` | `~/Library/Application Support/Reflex` | usage history |

### API

`GET /api/state` · `POST /api/route {text, dry?}` · `POST /api/explain {text}` ·
`POST /api/send {pane, text}` · `POST /api/side {pane, text}` ·
`POST /api/spawn {cwd, kind?, text}` · `POST /api/cancel {id}` ·
`POST /api/answer {item, key}` · `POST /api/dismiss {item}` ·
`GET /api/pane?id=&lines=&format=ansi` · `GET /api/folders?q=` · `POST /api/focus {pane}` ·
`POST /api/reindex` · `GET /api/health`. Every `/api/*` call except health
needs the token.

## Security

reflexd can type into your agents, so every API call needs the bearer token
(a 0600 file in Application Support). The phone remote listens on the network
only when you enable it; prefer Tailscale (WireGuard-encrypted) over a plain
LAN, and use "New link" in Settings to revoke an old QR code. Side-question
forks for Claude run in plan (read-only) mode and are never saved.

## Development notes

- Bend requires callees above callers and no mutual recursion;
  `scripts/bend-order.py <file>` topologically sorts a module's defs.
- Pure modules (`Core`, `Route`, `Index`, `Http`, `Model`, `Js`) must check
  clean; IO lives in `main.bend`, `Herdr.bend`, `Fs.bend` and the three C
  effects in `host.c`.
- `docs/bend-build-speed.md` explains Bend build times on large programs and
  the `BUN_JSC_forceRAMSize` setting the build script uses.
