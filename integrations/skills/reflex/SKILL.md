---
name: reflex
description: Move this agent session to another machine (a boat.dev sandbox, or a machine herdr-core has added) with Reflex, keeping the conversation. Use when the user asks to move, send or continue this session on boat, a sandbox, a VM or another machine, or when Reflex asks you to build the user's boat template.
---

# Moving a session with Reflex

Reflex (the Mac app that runs your terminal) moves a session between turns:
it closes you here and resumes the same conversation on the other machine, in
the same project at the same `~` path. You can't move yourself mid-turn, so you
prepare the machine, ask Reflex, and end your turn. The user approves every
move in Reflex unless they set auto-approve in Settings.

Everything goes through the `reflex` command (`reflex --help`). If it isn't on
PATH, it's at `/Applications/Reflex.app/Contents/Resources/scripts/reflex.sh`.
Run commands on the machine with `hc exec --on NAME -- sh -lc '...'` (exit codes
come back), and write files there with `hc file write --on NAME PATH`.

## 1. Is there a template?

```sh
reflex template        # exit 0 current, 1 stale (lists what changed here), 2 none
```

The template is a saved boat snapshot in the user's own account, private to
them: this machine's tools and configuration, set up once, so later moves
start from it in seconds. **Current:** skip to step 4 and use
`reflex machine new --template`. **None or stale:** build it (steps 2 and 3).
A stale one is rebuilt from scratch in the same way.

## 2. Build the template

```sh
NAME=$(reflex machine new)    # a fresh boat sandbox, added to herdr-core
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
- **supercomputer.** If `supercomputer` is on PATH here, install it there:
  `curl -LsSf https://astral.sh/uv/install.sh | sh`, then
  `uv tool install git+https://github.com/monotykamary/supercomputer`.
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
  "installed": ["pi packages: npm:pi-tps, npm:pi-retry, ...", "uv, supercomputer"],
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

On the machine you built (it's set up already) or on a new one from the
template:

```sh
NAME=$(reflex machine new --template)   # only when you didn't just build one
reflex sync $NAME                       # this project, at the same ~ path there
reflex creds $NAME                      # the user's logins, mcporter, the manifest's secrets
reflex move self --to $NAME
```

Then tell the user in one line where you're going, and **end your turn**.
Reflex asks them, closes you here once you're idle, and resumes this
conversation there. Commit nothing just for the move: uncommitted and untracked
files go with `reflex sync`.

To a machine Reflex didn't make (`hc machine ls`): `reflex sync` and
`reflex move self` work the same. Run `reflex creds NAME --any` only after the
user says to copy their logins there.

## After a move

On the other machine `$HOME` differs (`/home/user` on boat), but the project is
at the same `~` path and the conversation is the one you had. Paths in earlier
messages that start with the old home are now under the new one. If something
from the old Mac is missing, install it there and tell the user. Don't move
back on your own.

## When it fails

Nothing is lost: the session stays here until Reflex resumes it there. On a
failure, say what failed. If the machine is no use, ask before removing it with
`reflex machine rm NAME` (the user may want to look at it). Never remove a
machine Reflex didn't make.
