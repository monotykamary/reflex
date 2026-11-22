---
name: reflex
description: Move this agent session between machines (this Mac, the user's other Macs, an instabox box) with Reflex, keeping the conversation, and fetch files from the Mac that moved it. Use when the user asks to move, send or continue this session on instabox, a sandbox, a VM or another machine, when Reflex asks you to move or to build the user's instabox template, when a file or folder you need is on the Mac this session came from, or when some work would be better on a box of its own (a lane: several agents at once, a heavy loop, work kept apart).
---

# Moving a session with Reflex

Reflex (the Mac app that runs your terminal, on this Mac or the one that
moved you here) moves a session between turns: it closes you where you are
and resumes the same conversation on the other machine, in the same project
at the same `~` path. You can't move yourself mid-turn, so you say where and
what the work needs, and end your turn. The user approves every move in
Reflex unless they set auto-approve in Settings. From another machine,
`reflex home` reaches that Reflex over herdr-core's line.

Everything goes through the `reflex` command (`reflex --help`). If it isn't on
PATH, it's at `/Applications/Reflex.app/Contents/Resources/scripts/reflex.sh`.
Run commands on the machine with `hc exec --on NAME -- sh -lc '...'` (exit codes
come back), and write files there with `hc file write --on NAME PATH`.

## 1. Is there a template?

```sh
reflex template        # exit 0 current, 1 stale (lists what changed here), 2 none
```

Reflex makes machines on instabox, from the user's instabox template. (It
can still make boat.dev sandboxes, each service with its own template, but
only when Reflex names boat: then add `--provider boat` to `reflex template`
and `reflex machine new` in every step below.)

The template is a saved snapshot in the user's own account, private to
them: this machine's tools and configuration, set up once, so later moves
start from it in seconds. **Current:** skip to step 4 and use
`reflex machine new --template`. **None or stale:** build it (steps 2 and 3).
A stale one is rebuilt from scratch in the same way.

## 2. Build the template

```sh
NAME=$(reflex machine new)    # a fresh instabox box, added to herdr-core
```

Make the new machine work like this one for the user's agents. **Read here,
change only there.** Work out what to do from what is on this Mac, and keep a
list of every file you read to decide (the manifest's `inputs`).

- **Harnesses.** claude, pi and codex are preinstalled there. Match versions
  where this Mac's are newer (`npm i -g ...`).
- **pi.** `~/.pi/agent/settings.json`'s `packages`. Each package that is a
  local path here (`../../VCS/.../pi-foo`) becomes its published package
  there: read its `package.json` (`name`, `repository`). Then use
  `pi install npm:NAME` when `npm view NAME version` answers, or
  `pi install git:URL` for a public repo. Only if neither exists, copy the
  folder to the same `~` path there (`reflex sync NAME FOLDER`) and keep the
  path. Copy the loose files from `~/.pi/agent/extensions/` and the
  non-secret settings too (theme, models, `APPEND_SYSTEM.md`, `AGENTS.md`,
  skills). Leave out `extensions/reflex-shells.ts`: Reflex installs it where
  it's needed. Then `pi list` there shows them. The sandbox comes with pi
  packages of its own (an mcp extension, say): remove the ones this Mac
  doesn't use, so pi starts there without extension warnings.
- **Claude and Codex.** The user's instructions (`~/.claude/CLAUDE.md`,
  `~/.codex/AGENTS.md`), skills, `settings.json` (hooks that point at local
  paths need those tools there too), and Codex's `config.toml`.
- **mcporter.** `~/.mcporter/mcporter.json` names its servers' commands
  (`bunx`, `uvx`, a local path). Install what they need there (bun, uv, a tool
  at the same `~` path). Don't copy the file itself or `credentials.json`:
  `reflex creds` copies both on every move, with `~` mapped.
- **supercomputer.** If `supercomputer` is on PATH here, install it there
  (it needs bun): `git clone https://github.com/monotykamary/supercomputer
  ~/.local/share/supercomputer/src && ~/.local/share/supercomputer/src/install.sh`.
  It runs on instabox with the box's own instabox login, so it has no
  settings or keys of its own to copy; a repo's `supercomputer.toml` says
  what its boxes need. Check it there with `supercomputer --help` (no batch:
  it would make boxes).
- **cswap** (claude-swap): leave it out of the template. `reflex creds`
  installs it on each machine Reflex makes, imports the accounts and
  activates the one active here.
- **The CLIs the user's instructions rely on** (`gh`, `bun`, `uv`, a linter):
  install those that are missing.
- `reflex skill install --on $NAME`, so the agent there has this skill too.

**No secrets in the template.** It is a snapshot the user may share one day.
Never copy a token, key or login into it. Before copying a config file, look
for keys (`key`, `token`, `secret`, `Bearer`, `sk-`). If a file is needed and
holds one (an extension's API key file, say), don't copy it: list it under
`secrets` in the manifest, and `reflex creds` copies it on each move. Don't run
`reflex creds` on this machine before the snapshot: `reflex snapshot` refuses a
machine that has logins on it.

When something can't be reproduced (a Mac-only app, a private repo), leave it
out and say so in `notes`. Don't stop for it.

## 3. Check it, then save it

Verify on the machine, and put each check in the manifest:
`claude --version`, `pi --version` and `pi list` (and `pi -p ok` printing no
extension warnings), `codex --version`, every
mcporter server's command found (`command -v`), `supercomputer --help`.

Write the manifest here, in a temp file:

```json
{
  "installed": ["pi packages: npm:pi-tps, npm:pi-retry, ...", "bun, supercomputer"],
  "checks": ["pi list: 24 packages", "claude 2.x", "..."],
  "inputs": ["~/.pi/agent/settings.json", "~/.mcporter/mcporter.json", "~/.claude/settings.json"],
  "secrets": ["~/.pi/agent/extensions/fireworks.json"],
  "notes": "what was left out, and why"
}
```

`inputs` are the files on this Mac the setup came from. Reflex rehashes them to
tell when the template goes stale, so list every one that would change it.

```sh
reflex snapshot $NAME --manifest /path/to/manifest.json
```

## 4. Move

Wherever you are (this Mac, another Mac, an instabox box), Reflex does the
copying, through the Mac it runs on: you say where to and what the work
needs. The machine is one Reflex named when it asked you to move, `here`
(the Mac Reflex runs on), one from `reflex home machines`, or a new instabox
box from the template (`reflex machine new --template`, on a Mac with
Reflex, when you have no machine yet).

### Say everything the work needs

The session should carry on there as if nothing moved. Only you know what
this work stands on, so before asking, go back over the conversation and
list every path it used: what you read, wrote, ran or were given.

- **Every other repository** you worked in (this project goes anyway). A
  worktree needs its repository too (the history lives there).
- **Files the user gave you**: a document in `~/Downloads`, a screenshot on
  the Desktop, a spec in `~/Documents`, a data set.
- **Work in progress outside git**: notes, handoff files, drafts, scratch
  folders (in `/tmp` too), generated data the next step reads, a local
  config the project needs.
- **Gitignored files the work needs** (a handoff note in `private/`, a
  `.env` the tests read): name each, since the project goes as git sees it.

Leave out what can be rebuilt there (`node_modules`, build output, caches),
and say what's too big to copy rather than waiting an hour. Then ask:

```sh
reflex move self --to NAME ~/code/other-repo ~/Downloads/spec.pdf private/handoff.md
```

Reflex answers at once (or says it doesn't know NAME). It copies this
project as git sees it (tracked and untracked files and `.git`), each path
you named (a repository as git sees it, anything else as it is), your
logins to a machine Reflex made, and this conversation (its subagents'
transcripts and Claude's memory for the project too), each to the same
path there: `~/x` is `~/x`, `/tmp/x` is `/tmp/x`, and worktrees' `.git`
files point at the copies. Tell the user in a line or two where you're
going, what you named and what you left behind, and **end your turn**: it
closes you once you're idle and resumes this conversation there. If the
user pressed the move button, the move is approved already; otherwise
they approve it in Reflex. Commit nothing just for the move.

## After a move

On the other machine `$HOME` may differ (`/data/home` on instabox), but what was
copied is at the same `~` path and the conversation is the one you had.
Paths in earlier messages that start with the old home are now under the
new one. A tool that's missing: install it there.

Keep a box light: it has 4 vCPUs unless the user chose a bigger size, and
its line home shares them. Send heavy work (builds, test suites, browsers,
benchmarks) through supercomputer rather than running it on the box; a box
kept busy answers slowly, and the user's windows on it
go blank while requests to their Mac stall.

A box's lifetime is Reflex's to keep: it renews it while you work or wait
on the user, and lets it pause once you go idle: its memory and programs are
kept, and it carries on where it was when the user resumes it, with you in
the same terminal. Don't change its idle pause (`instabox auto-suspend`) or
pause it yourself, and don't ask the user to.

### Something missing? Ask the Reflex that moved you

The Mac that moved this session is still there, a line away, and through
it every machine it reaches (`reflex home machines`; `reflex on NAME …` asks
about one of them):

```sh
reflex home ls ~/Downloads             # what's in a folder where you came from
reflex home fetch ~/Downloads/spec.pdf ~/code/notes   # copy them here, same ~ path
reflex home machines                   # the machines that Reflex reaches
reflex home run 'brew list | grep foo' # a command there: its output and exit code come back
reflex home run --cwd ~/code/app --timeout 300 'git log --oneline -5'
reflex on mini fetch ~/notes/plan.md   # any machine that Reflex reaches, by name
reflex on here run 'sw_vers'           # "here": the Mac that Reflex runs on
```

The user allows each (or Settings allows them; commands from a box
ask unless the user chose Always allow, so ask for what you need in one
command rather than many);
`fetch` waits until the files are here, then prints where they went, and
`run` exits with the command's exit code. Prefer `fetch` for files and
reading them here. Don't move back on your own.

## Lanes: a box for work of its own (optional)

Most work needs no machine of its own: a worktree where you are is enough.
When some doesn't fit here (several agents at once that would fight over
this machine's CPUs or memory, a long build or test loop, something you
want kept apart), you can give it a lane: an instabox box of its own. It's
your call; nothing makes one for you.

```sh
reflex lane new alg-a --repo ~/VCS/gdp-wired                # worktree ~/VCS/gdp-wired-alg-a on lane/alg-a
reflex lane new alg-b --repo ~/VCS/gdp-wired-alg-b          # that worktree itself, on its own branch
reflex lane new perf --repo ~/VCS/gdp-wired --branch fix/x --base origin/main --size 16x32
```

It prints the machine (`lane-NAME`) and the worktree's path there. On an
instabox box the lane is a fork of it, so every repository, dependency and
build is already there at the same paths, in seconds; from a Mac it's a new
box with the repository copied. From a box with no instabox login, the Reflex
that moved you makes it, with its own. At most 10 lanes are up at once.

A lane is a machine, not one worktree: start a few agents there, each in a
worktree of its own, and they show up in Reflex like any machine's:

```sh
hc exec --on lane-alg-a -- git -C ~/VCS/gdp-wired worktree add ~/VCS/gdp-wired-alg-a2 -b lane/alg-a2
hc run --on lane-alg-a --cwd ~/VCS/gdp-wired-alg-a --bg --name alg-a claude "$(cat brief-a.md)"
hc run --on lane-alg-a --cwd ~/VCS/gdp-wired-alg-a2 --bg --name alg-a2 claude "$(cat brief-a2.md)"
hc wait lane-alg-a/alg-a                                     # rather than sleep
```

When the work is done:

```sh
reflex lane fetch alg-a     # every branch the lane made or moved, back into the repository here
reflex lane rm alg-a        # refused while anything there isn't fetched, pushed or committed
reflex lane ls
```

A branch checked out here comes back as `lane-NAME/BRANCH`, to merge like a
remote's. An idle lane pauses itself after 10 minutes (only its disk costs)
and comes back in seconds; `reflex machine pause lane-NAME` pauses it now.
Heavy runs still go through `supercomputer`, from the lane like from
anywhere. Remove the lanes you made once their work is back; ask before
`reflex lane rm NAME --force`, which drops what's left.

## When it fails

Nothing is lost: the session stays here until Reflex resumes it there. On a
failure, say what failed. If the machine is no use, ask before removing it with
`reflex machine rm NAME` (the user may want to look at it). Never remove a
machine Reflex didn't make.
