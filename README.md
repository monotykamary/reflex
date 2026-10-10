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
  folder? is this a side question? does it continue an earlier conversation?* —
  and comes back as keys and probabilities in about a second. Your text is
  delivered verbatim. Reflex decides *where* and *when*; your agents decide
  *what*.

The routing and dispatch core is written in [Bend](https://bend-lang.com) and
its safety rules are stated as laws and machine-checked (`daemon/LAWS.bend`).

```text
 Reflex.app (Swift)                          phone (web page)
 edge tab · rail · ⌥⌥ bar · inbox · terminals  paired once by QR, over Tailscale
          │  HTTP + bearer token                  │
          └──────────────┬────────────────────────┘
                 reflexd (Bend, native)
     actor ── Core.step(State, Msg) → (State, dispatches)   ← pure, proven
       │ ticker · poller · indexer · http · exec
       ├── herdr socket (agents, screens, prompts, keys, workspaces)
       ├── jev-fabric serve (one typed Jev call per request)
       └── reflex-scan.sh / reflex-fork.sh (folder facts, /btw forks)
```

## What it does

| | |
|---|---|
| **Edge tab & rail** | While agents work, a small tab at the right screen edge shows a spinning ring per working agent, amber for one waiting on you, green for done. Hover it (or rest on an empty edge for half a second) for the rail: inbox, your agents, Ask, Settings, ⋯. A question waiting on you sits beside it — answer with 1, 2, 3. Click the dots for every agent (grouped only when a project has several; counts per state past 8 agents), with one click to its terminal. |
| **⌥⌥ Ask bar** | Double-tap Option and type. A few words search your sessions, most recently used first (⏎ opens that terminal). A sentence or question becomes a request: a Raycast-style list of where it could go — live sessions, folders to start one in, earlier conversations to resume — with Jev's pick on top and a weight per row. ⏎ sends (the terminal stays closed); ⌘⏎ sends and opens it. `/claude`, `/pi`, `/codex`… pick the agent for new sessions, `/new` starts in a new folder, `/btw` asks on the side, `/folder` picks any folder, `/resume` lists earlier sessions. Paste or drop images: Jev routes on your words, the agent gets the image. |
| **It remembers** | Where your recent requests went, so “also add tests for that” lands in the same session; and where you overrode Jev, so a similar request goes where you sent it. Kept on your Mac; Settings → Routing shows it and forgets it. |
| **Unsure? It asks.** | When Jev isn't sure, nothing is sent on its own: its best guess is highlighted for you to confirm. Without Jev at all (no key, not installed) the bar still works — you choose. |
| **Questions** | Every question an agent stops on — numbered options, Claude's `AskUserQuestion` (several questions, multi-select with a Next step, the review), arrow menus like the folder-trust prompt — becomes a card you can answer from the rail, the inbox or your phone. |
| **Inbox** | Questions first, then updates: what each session said last (read from Claude's and pi's own session files, otherwise its screen, cleaned of terminal noise). Opening a session clears its notifications. |
| **Resume** | Earlier Claude, pi and Codex sessions (from their own session files) and Claude background sessions (`claude agents`) come back into herdr: ⏎ resumes or attaches, ⌘⏎ forks. Jev may offer one when a request clearly continues it — only when sure, and never over a live session (both proved). A background session nobody is watching notifies you when it finishes. |
| **btw** | Start with `btw` to ask without interrupting: Claude Code gets its native `/btw`; pi (and Claude when it is blocked on a dialog) gets a headless, unsaved fork of its session. |
| **Terminals** | A real terminal on any agent (SwiftTerm, attached through herdr): full colour, keys and resizing go straight to its TUI. One window per session. Ghostty themes with light and dark slots, Geist Mono when installed. |
| **Phone** | ⋯ on the rail → *Take Reflex with You*: a QR code that works once and expires in ten minutes. On the phone: your agents, their questions with big answer buttons, updates, and a live terminal you can type into (keys for esc, tab, arrows, ⏎, ^C, ctrl). Light, dark or system. |
| **Keep awake** | While agents work (or always), the Mac doesn't idle-sleep; on battery below 20% (adjustable) it lets go. |

## Requirements

- An Apple Silicon Mac on **macOS 26** or later.
- [herdr](https://herdr.dev) 0.9+, with its agent integrations
  (`herdr integration install claude && herdr integration install pi`).
- At least one agent: [Claude Code](https://claude.com/claude-code), Codex, pi, …
- For routing: jev-fabric and a Jev provider key (TypeSafe by default; Reflex
  can reuse the key pi already has). Without them everything else works and
  you pick where requests go.
- For the phone: [Tailscale](https://tailscale.com) on the Mac and the phone
  (the Mac app, Homebrew or a headless `tailscaled` all work).

## Build and run

Building also needs Bend 2.0.36 (`curl -fsSL https://bend-lang.com/install.sh | sh`)
and Xcode / Swift 6.

```sh
scripts/build-app.sh          # reflexd + Reflex.app → build/Reflex.app
open build/Reflex.app
```

The first run walks you through it: herdr and its integrations, connecting
Jev (and trying a request without sending anything), the folders to index,
⌥⌥ and the edge. Every check also lives in Settings → Setup.

### A release

```sh
scripts/release.sh            # ad-hoc signed DMG: runs on this Mac; checks the
                              # app under the hardened runtime
DEVELOPER_ID="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=reflex \
  scripts/release.sh          # signed, notarized and stapled build/Reflex-<version>.dmg
```

`NOTARY_PROFILE` is a notarytool keychain profile
(`xcrun notarytool store-credentials reflex --apple-id … --team-id …`).

### Testing

- `bend daemon/PROOF.bend --check-only` — every law (`ALL PROOFS CHECK`).
- `daemon/tests/asks.bend` — the answers read off captured Claude Code screens
  (numbered, multi-select, review, arrow menu, idle).
- `REFLEX_PROFILE=<folder> build/Reflex.app/Contents/MacOS/Reflex` — Reflex as
  a new user meets it: its own settings, support folder, Keychain entry and
  port. Add `REFLEX_PATH=/usr/bin:/bin` to see it with nothing installed.

### Daemon only

```sh
scripts/build-app.sh --daemon
REFLEX_TOKEN=dev REFLEX_SCAN=$PWD/scripts/reflex-scan.sh REFLEX_FORK=$PWD/scripts/reflex-fork.sh \
  REFLEX_WEB=$PWD/web JEV_PROVIDER=typesafe TYPESAFE_API_KEY=... build/reflexd
curl -H 'authorization: Bearer dev' localhost:47823/api/state
```

| Variable | Default | |
|---|---|---|
| `REFLEX_PORT` / `REFLEX_BIND` | `47823` / `127.0.0.1` | the app picks the bind for the phone remote |
| `REFLEX_TOKEN` | generated (printed once) | bearer token for every `/api/*` call |
| `REFLEX_HERDR_SOCKET` / `HERDR_SESSION` | default herdr session | |
| `REFLEX_HARNESS` | `claude` | agent for new sessions |
| `REFLEX_THRESHOLD` | `6000` | how sure Jev must be to act alone (basis points; the app fixes it at 60%) |
| `REFLEX_ROOTS` / `REFLEX_SCAN_DEPTH` | `~/VCS` / `6` | where the folder index looks for git repos, and how deep |
| `REFLEX_FOLDERS_FILE` | — | extra folders to index, one per line |
| `REFLEX_JEV` | `jev-fabric` | the jev-fabric binary |
| `REFLEX_DATA` | `~/Library/Application Support/Reflex` | usage history, earlier sessions, pairing |

### API

`GET /api/state` · `POST /api/route {text, dry?, memory?}` · `POST /api/candidates {text, harness?, memory?}` ·
`POST /api/explain {text}` · `POST /api/send {pane, text}` · `POST /api/side {pane, text}` ·
`POST /api/spawn {cwd, kind?, text}` · `POST /api/resume {cwd, kind, session, mode, text}` ·
`POST /api/answer {item, key}` · `POST /api/dismiss {item}` · `POST /api/note {pane, agent, title, body}` ·
`GET /api/pane?id=&lines=&format=ansi` · `POST /api/keys {pane, key}` · `POST /api/text {pane, text}` ·
`POST /api/focus {pane}` · `POST /api/close {pane}` · `GET /api/folders?q=` · `GET /api/sessions` ·
`POST /api/reindex` · `POST /api/cancel {id}` · `GET /api/jev/ping` · `GET /api/health` · `POST /api/pair {code}`.
Every call except health and pair needs the token.

## How routing works

1. **Candidates are built deterministically.** Live agents come from herdr
   (kind, folder, state, title, last lines of output). Folders come from the
   index (`scripts/reflex-scan.sh`: every git repo under your roots with its
   description, recent commit subjects, branch, activity age and how often you
   started sessions there; and their parents: a plain folder holding two or
   more repos, like `~/VCS/work/acme`, described by what it holds, for work that
   spans them; past twelve it is a collection, offered only when named or
   matched), ranked by `daemon/Index.bend`: folders you name
   (or the start of whose name you write) are pinned first, then lexical
   matches, then recent activity. Earlier conversations are ranked the same
   way. At most 8 folders, 12 agents and 5 earlier conversations are offered.
2. **What you did before.** The app adds a few lines: where your last requests
   went, and your corrections for similar requests.
3. **One Jev call, typed questions:** `target` (which live session, or new),
   `folder`, `side` (is this a side question), `resume` (does it continue an
   earlier conversation).
4. **Typed answer → decision** (`daemon/Route.bend`): every key maps back to a
   candidate, or the request waits for you. The harness for a new session is
   the one you name in the text, otherwise your default.

Try it without sending anything: `POST /api/route {"text": "...", "dry": true}`
returns the decision; `POST /api/explain` returns the exact Jev request.

## Laws

`bend daemon/PROOF.bend --check-only` checks every law in `daemon/LAWS.bend`:

- `fired_are_ripe`, `kept_are_unripe`, `fire_partitions`, `cancel_removes` —
  scheduled dispatches run exactly when due, once, and a cancelled one never.
- `tick_runs_ripe`, `tick_keeps_unripe`, `enqueue_runs_nothing`,
  `answer_runs_nothing` — only the clock runs anything.
- `new_blocked_agent_asks`, `finished_turn_reports`, `answered_question_clears`
  — inbox transitions.
- `unsure_target_never_acts`, `unsure_folder_never_acts`,
  `unsure_resume_changes_nothing` — when Jev is unsure, Reflex asks; it never acts.
- `live_session_beats_resume` — a request never resumes an old conversation
  over a live session that fits.
- `blocked_agent_gets_no_native_btw` — a side question never types into a
  blocked agent's TUI.
- `rank_is_bounded` — Jev is offered at most k folders.

The laws cover reflexd's policy. herdr, Jev, the harnesses and the Bend
runtime are assumptions. `--verdict` re-checks with Bend's Lean-proven kernel.

## Security and privacy

- reflexd can type into your agents, so every API call needs a bearer token.
  The Mac app uses its own token, made fresh each launch.
- The phone gets its token by trading a one-time code (the QR) that expires in
  ten minutes; the QR never carries the token. The phone token works only while
  the phone remote is on; *Sign Out Phones* in Settings replaces it.
- The phone remote prefers Tailscale (WireGuard-encrypted, and private to your
  devices). With `tailscaled` in userspace mode reflexd stays on localhost and
  is reachable from your tailnet only. Without Tailscale it uses your Wi-Fi only
  when you allow it, with a warning: that traffic is unencrypted.
- Everything stays on your Mac: routing memory (`memory.json`), the index of
  earlier sessions (`sessions.tsv`), pasted images (a temporary folder). No
  telemetry.
- Routing sends Jev's provider your request with the short context Jev chooses
  from: your live sessions' titles and last few screen lines, candidate
  folders' names, descriptions and recent commit subjects, earlier
  conversations' titles and last prompts, and where your recent requests went.
  `POST /api/explain` shows exactly what would be sent. Images never are.
- Side-question forks for Claude run read-only and are never saved.

## Development notes

- Bend requires callees above callers and no mutual recursion;
  `scripts/bend-order.py <file>` topologically sorts a module's defs.
- Pure modules (`Core`, `Route`, `Index`, `Http`, `Model`, `Js`) must check
  clean; IO lives in `main.bend`, `Herdr.bend`, `Fs.bend` and the three C
  effects in `host.c`.
- `docs/bend-build-speed.md` explains Bend build times and the
  `BUN_JSC_forceRAMSize` setting the build script uses; `docs/design.md` the
  design language.
- Dev hooks (`REFLEX_SHOW=bar|inbox|rail|agents|settings|onboarding|pairing|…`)
  open a surface at launch for screenshots and tests.

## License

[MIT](LICENSE). The vendored JSON parser in `daemon/vendor/strict-json` is
Apache-2.0 (see its `LICENSE` and `PROVENANCE.md`).
