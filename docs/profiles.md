# Harness profiles and the credential holder

Design notes, 2026-11-24. Not built yet.

## Profiles

A profile is one harness plus one name: `@claude[work]`, `@codex[personal]`. Bare `@claude` is the
user's real home and login, untouched. A profile exists only where there is an account for it.

- Only the harness's own files and a Keychain are separate per profile. Everything else on the machine
  (repos, ssh, gh, git config, other tools) is shared through links back to the real home.
- No resuming across profiles. Work crosses only by handoff: Reflex, which runs outside every profile,
  copies one picked session (summary or transcript) into the target profile.
- Profiles can't read each other's folders (Seatbelt on a Mac; on Linux the other profiles' folders are
  covered by empty ones inside the mount namespace).
- Reflex tags each session with its profile, so a resume starts in the same profile. A folder may pin a
  default profile.

### Isolation per OS

- **macOS:** run the harness with `HOME=~/.reflex/profiles/<harness>/<name>/home`. `security` resolves
  the default Keychain from `$HOME`, so the profile home gets its own
  `Library/Keychains/login.keychain-db`, isolated from the real one (tested: an item added there is not
  in the real Keychain; claude and codex report not logged in). Its password is random, kept in the
  real login Keychain, and Reflex unlocks it before starting an agent. A Seatbelt profile denies other
  profiles' folders. sandbox-exec cannot remap paths; it only enforces.
- **Linux boxes:** a root-made private mount namespace binds the profile's folders over the real ones,
  then drops back to the user, so sudo keeps working:
  `sudo --preserve-env unshare --mount --propagation private sh -c 'mount --bind A B && exec setpriv --reuid=$U --regid=$U --init-groups -- CMD'`.
  bubblewrap also works but sets no_new_privs, which breaks sudo.

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

### Still open

- Whether reusing a spent refresh token revokes the whole login server side. Unconfirmed for both
  Anthropic and OpenAI (OpenAI: a token can be reused for about an hour, then `refresh_token_reused`).
  Rule 4 makes it moot.
- A clean way for the holder to make Claude and Codex refresh early without spending a model request.
- Claude logins end 30 days after sign-in whatever the holder does, and Codex's `exp` looks capped the
  same way: the holder needs a real sign-in about monthly, pushed like any refresh.
- Codex `auth_mode: "chatgptAuthTokens"` never refreshes and would suit non-holders, but loading it from
  a file is undocumented and untested.
