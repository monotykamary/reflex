# Harness profiles and the credential holder

Design notes, 2026-11-24. The credential holder is built in keys/ (below); profiles are `reflex profile`.

## Profiles

A profile is one harness plus one name: `@claude[work]`, `@codex[personal]`. Bare `@claude` is the
user's real home and login, untouched. A profile exists only where there is an account for it.

- Only the harness's own files and a Keychain are separate per profile. Everything else on the machine
  (repos, ssh, gh, git config, other tools) is shared through links back to the real home.
- No resuming across profiles. Work crosses only by handoff: Reflex, which runs outside every profile,
  copies one picked session (summary or transcript) into the target profile.
- Nothing is hidden: an agent in a profile reads the whole filesystem, your own sessions and memory and
  other profiles' included, as it would outside one. Only the login and the session folders its harness
  writes to are the profile's. (Hiding was tried and removed in 0.1.97: a Seatbelt profile on a Mac
  stopped every sandbox the agent starts itself, Codex's and Claude's command sandboxes and SwiftPM
  alike, `sandbox_apply: Operation not permitted`, and it hid the project memory agents rely on; the
  user wants agents to read freely.)
- Reflex tags each session with its profile, so a resume starts in the same profile. A folder may pin a
  default profile.

### Per OS

- Claude, Codex and pi take their folder by a setting (below); the others run with
  `HOME=~/.reflex/profiles/<harness>/<name>/home`, whose entries link back to the real home.
- **macOS:** `security` resolves the default Keychain from `$HOME`, so such a profile home gets its own
  `Library/Keychains/reflex-profile.keychain-db` (not named "login": macOS unlocks a login keychain
  only with your login password), isolated from the real one (tested: an item added there is not in
  the real Keychain). Its password is random, kept in the real login Keychain, and Reflex unlocks it
  before starting an agent.

Harness homes: Claude `CLAUDE_CONFIG_DIR` (its Keychain item becomes `Claude Code-credentials-<8 hex of
sha256(dir)>`), Codex `CODEX_HOME`, pi `PI_CODING_AGENT_DIR`, agy only `$HOME` (`~/.gemini`).

## The credential holder

Claude, Codex and pi refresh tokens work once: the refresh replaces them. Copying one login to several
machines therefore logs them out: the first to refresh invalidates everyone else's copy. Today's
`creds()` in `scripts/reflex.sh` does exactly this for `.codex/auth.json` and pi's `auth.json`.

Instead, for each profile one machine is the **holder**, the only one that ever refreshes. It refreshes
early and pushes the result to every other machine. Rules:

1. **One refresher per profile.** Holder changes are leases: a handover sends the latest copy then
   stops; a takeover after the holder vanished waits until its lease has run out, and a holder checks
   its lease before every refresh, even offline. State this as a gdp-wired law: at most one machine
   refreshes per profile.
2. **The harness refreshes itself.** On the holder, the real harness does the token call; Reflex only
   notices the changed credentials and sends them. Reflex never calls the sign-in servers itself.
3. **Pushes are numbered.** A machine never replaces a newer copy with an older one. A machine that was
   away fetches the latest before Reflex starts an agent there, and refuses to start on old credentials.
4. **Non-holders hold no usable refresh token**, so a late push fails one request instead of spending
   the holder's token. The placeholder differs per harness (below).
5. **Safety net.** A watcher on every machine sends any copy a harness refreshed anyway straight to the
   holder, which takes it as newest and pushes it out.
6. Copilot (in pi) and agy's Google sign-in don't rotate; they are copied as they are.

### What each harness does (read from source, 2026-11-24)

| | Claude Code 2.1.330 | Codex 0.172.0 | pi 1.6.0 |
|---|---|---|---|
| Store | Mac: Keychain `Claude Code-credentials`, account `$USER`, file only if no item. Linux: `<config>/.credentials.json` | `$CODEX_HOME/auth.json` (default `file` store); `keyring`/`auto` let a Keychain entry shadow the file | `<agent dir>/auth.json`, one entry per provider |
| Refreshes when | 5 min before `expiresAt`, before each request; also on 401; the daemon refreshes ahead | 5 min before the JWT `exp`, per request; also on 401. No timer | 5 min before `expires` (Anthropic stores expiry minus 5 min), per request. Not on 401 |
| Token lifetime | access about 8 h; the login itself ends 30 days after sign-in, refreshing doesn't extend it | one sample: 3.7 days, `exp` exactly 30 days after password sign-in | from the provider |
| Running session picks up a push | yes: re-reads before each request (file mtime on Linux; Keychain at most every 30 s on a Mac); a 401 adopts a newer stored token | yes, but only at its pre-refresh reload or on a 401; nothing watches the file | yes: checks the file's stat before every read and reloads |
| Refresh race guards | lock `<config>/.oauth_refresh.lock`, re-read under lock, compare-and-swap save adopts a newer write | in-process semaphore, reload first, flock `$CODEX_HOME/auth.lock`, compare-and-swap save; a push mid-refresh wins | proper-lockfile on `<realpath>.lock`, re-read under lock, keeps a fresh entry another process wrote |
| On refresh failure | blanks the stored login (`refreshToken: ""`, `loginEnded`) unless a sibling already rotated it; needs `/login` | keeps auth.json, logs the failure, next request reloads from disk | keeps the entry, says run `/login`, next request retries |
| Non-holder placeholder | omit `refreshToken` or set null; never `""` (that means logged out) | `""`; removing the key breaks parsing | any non-empty string |
| Push write | Mac: `security add-generic-password -U` into the profile's Keychain, and remove any stray `.credentials.json` beside it (Claude would watch that instead). Linux: atomic write, 0600 | atomic temp+rename under a lock on `auth.lock`, same `account_id`; pin `cli_auth_credentials_store = "file"` on non-holders | `mkdir <realpath>.lock`, merge only that provider's entry, write 0600, `rmdir` |
| Holder forces an early refresh | open: the daemon's proactive refresh, or a request | open | `pi auth print-bearer-token --provider X --min-expiry 1h > /dev/null` |

Holder cadence: Claude at least every 8 h; Codex daily or with under a day left; pi with an hour or
more to spare. The holder pushes straight after each refresh.

### Built: `reflex-keys` (keys/)

A Bun program, shipped as `bun build --compile` binaries (`cd keys && bun run build`:
`dist/reflex-keys-darwin-arm64`, `dist/reflex-keys-linux-x64`). Its records live in
`~/.reflex/keys/`; the machine's identity is `~/.reflex/id` (`reflex id`); other machines are
reached with `hc exec --on M -i` running `~/.local/bin/reflex-keys` there, payloads on stdin and
stdout only.

    reflex-keys seed SPEC               this Mac, where SPEC is signed in, holds it (epoch 1)
    reflex-keys watch [--quiet]         the service on every Mac (a LaunchAgent, KeepAlive)
    reflex-keys tick                    one pass of what watch does every ~10 min
    reflex-keys hold SPEC --on M        handover: the holder stops, sends its newest copy, epoch + 1
    reflex-keys hold SPEC --on M --force    the holder gone for good: M, signed in again, takes over
    reflex-keys status [--json]         holder, epoch, generation, expiry, login end, who's current

The protocol is `keys/laws/protocol.ts`, a gdp-wired rule over any number of machines. Its laws
are proven and kernel-checked with no assumed invariant: at most one machine can refresh, at
most one holds the lease, a non-holder never stores a usable refresh token, the holder has the
newest generation, a receiver's generation and epoch never decrease, and after a handover the
new holder has the newest generation. Five broken variants are refused by real runs:
- a handover that doesn't stop the old holder;
- a forced takeover;
- no version check;
- a push carrying the token;
- a handover sending an older copy.

`src/lease.ts` holds one machine's decisions. It is run beside the compiled rule on 12,000
random steps, and every map cell must agree. `bun test` runs all of it.

Holder triggers, read from each harness's source on 2026-11-24:

| | How the holder makes it refresh | When |
|---|---|---|
| Claude | its own daemon, `claude daemon run --log-file ~/.reflex/keys/claude-SPEC.log` with the profile's env, kept running by `watch` on the holder | about 4 min before expiry |
| Codex | `codex app-server`: `initialize`, `initialized`, `account/read {refreshToken: true}` | under a day left, or a day since the last |
| pi | `pi auth print-bearer-token --provider X --min-expiry 120m` | under 2 h left |
| opencode, grok | none (they refresh themselves when used on the holder) | - |
| agy, amp, Copilot | don't rotate: copied as they are | - |

`watch` runs these pieces:
- **Change check, every ~15 s.** It reads the stores of the profiles this Mac holds. A change is
  a new generation, pushed straight away.
- **Full tick, every ~10 min,** also at start and after a sleep. Codex and pi are refreshed when
  due, newer copies are taken, and machines that are behind are brought up to date.
- **Claude daemons.** One `claude daemon run` runs per Claude profile held here.
  - None is started if `claude daemon status` says one already runs for that config.
  - It is restarted with backoff (5 s doubling to 10 min) when it exits.
  - It is stopped by its PID when this Mac stops holding the profile.
  - A small sh guard kills it when `watch` is gone, even after a SIGKILL.
- **Log:** `~/.reflex/keys/watch.log`, rotated at 256 KB into `watch.log.1`.

Receivers get Claude's new token at most about 4 minutes before the old one ends. A Claude
started fresh on a receiver in the last 5 minutes of a token may count itself signed out until
the push lands.

Codex's `account/read` refresh is a forced refresh through its own guarded reload and locks.

Placeholders and locks per harness:
- Claude: `refreshToken` left out. Writes go under `<config>/.storage-write.lock`; a stray
  `.credentials.json` beside a Mac's Keychain item is removed.
- Codex: `refresh_token: ""`. Writes go under flocks on `auth.lock`, then `auth.json.lock`; the
  account must match.
- pi: `reflex-keys:not-the-holder`, written under `<realpath>.lock`. Only `anthropic` and
  `openai-codex` rotate.
- grok: `refresh_token` left out, under a flock on `auth.json.lock`.
- opencode: rows of `credential` in `opencode.db`, written with SQL. Rotating rows (openai, xai,
  opencode, gitlab) get `refresh: ""`, `expires: 0`. MCP rows stay per machine.
- amp: `secrets.json`, without its `mcp-oauth-*` entries.

A usable refresh token found on a non-holder is replaced by a placeholder at the next tick. The
safety net of rule 5 is reduced to that.

### Still open

- Whether reusing a spent refresh token revokes the whole login server side. Unconfirmed for both
  Anthropic and OpenAI (OpenAI: a token can be reused for about an hour, then `refresh_token_reused`).
  Rule 4 makes it moot.
- A clean way for the holder to make Claude and Codex refresh early without spending a model request.
- Claude logins end 30 days after sign-in whatever the holder does, and Codex's `exp` looks capped the
  same way: the holder needs a real sign-in about monthly, pushed like any refresh.
- Codex `auth_mode: "chatgptAuthTokens"` never refreshes and would suit non-holders, but loading it from
  a file is undocumented and untested.
