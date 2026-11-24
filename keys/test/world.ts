// A few machines in temp folders, reached through a fake `hc`; fake harnesses and a fake
// sign-in server whose refresh tokens work once.
import {chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs'
import {tmpdir} from 'node:os'
import {join, resolve} from 'node:path'

const KEYS = resolve(import.meta.dir, '..')
const BUN = process.execPath

export type World = ReturnType<typeof world>

export function world(machines: Record<string, 'darwin' | 'linux'>) {
  const root = mkdtempSync(join(tmpdir(), 'reflex-keys-test-'))
  const bin = join(root, 'bin')
  mkdirSync(bin, {recursive: true})
  const sh = (name: string, body: string) => { writeFileSync(join(bin, name), `#!/bin/sh\n${body}\n`); chmodSync(join(bin, name), 0o755) }
  for (const t of ['claude', 'codex', 'pi']) sh(t, `exec "${BUN}" "${KEYS}/test/fakes/harness.ts" ${t} "$@"`)
  // herdr-core, as far as reflex-keys uses it
  sh('hc', `
case "$1" in
  machine)
    printf '{"machines":['; sep=
    for d in "$WORLD"/m/*; do n=\${d##*/}; [ "$n" = "$SELF" ] && continue
      st=connected; [ -f "$WORLD/down/$n" ] && st=disconnected
      printf '%s{"name":"%s","state":"%s","temporary":false}' "$sep" "$n" "$st"; sep=,; done
    printf ']}\\n' ;;
  exec) shift; on=
    while [ $# -gt 0 ]; do case $1 in --on) on=$2; shift 2 ;; -i) shift ;; --timeout) shift 2 ;; --) shift; break ;; *) break ;; esac; done
    [ -f "$WORLD/down/$on" ] && { echo "$on isn't connected" >&2; exit 255; }
    d="$WORLD/m/$on"; [ -d "$d" ] || { echo "no machine $on" >&2; exit 255; }
    cd "$d" && exec env HOME="$d" SELF="$on" REFLEX_KEYS_OS="$(cat "$d/.os")" "$@" ;;
  *) echo "fake hc: $*" >&2; exit 2 ;;
esac`)
  for (const [name, os] of Object.entries(machines)) {
    const d = join(root, 'm', name)
    mkdirSync(join(d, '.local', 'bin'), {recursive: true})
    mkdirSync(join(d, '.reflex'), {recursive: true})
    writeFileSync(join(d, '.os'), os)
    writeFileSync(join(d, '.reflex', 'id'), `${name}-id\n`)
    writeFileSync(join(d, '.local', 'bin', 'reflex-keys'), `#!/bin/sh\nexec "${BUN}" "${KEYS}/src/cli.ts" "$@"\n`)
    chmodSync(join(d, '.local', 'bin', 'reflex-keys'), 0o755)
  }
  const env = (name: string): Record<string, string> => ({
    PATH: `${bin}:/usr/bin:/bin:/usr/sbin:/sbin`, HOME: join(root, 'm', name), SELF: name, WORLD: root, USER: 'tester',
    REFLEX_KEYS_OS: machines[name], REFLEX_KEYS_STORE: 'file', TMPDIR: tmpdir(), FAKE_LOG: join(root, 'fake.log'),
  })
  const transcript: string[] = []
  return {
    root,
    home: (name: string) => join(root, 'm', name),
    path: (name: string, ...rel: string[]) => join(root, 'm', name, ...rel),
    env,
    run(name: string, args: string[], input?: string, extra: Record<string, string> = {}) {
      const r = Bun.spawnSync([BUN, join(KEYS, 'src', 'cli.ts'), ...args], {cwd: join(root, 'm', name), env: {...env(name), ...extra}, stdin: input === undefined ? 'ignore' : Buffer.from(input), stdout: 'pipe', stderr: 'pipe'})
      const out = r.stdout.toString(), err = r.stderr.toString()
      transcript.push(out, err)
      return {code: r.exitCode, out, err}
    },
    down: (name: string) => { mkdirSync(join(root, 'down'), {recursive: true}); writeFileSync(join(root, 'down', name), '') },
    up: (name: string) => rmSync(join(root, 'down', name), {force: true}),
    transcript: () => transcript.join('\n'),
    log: () => { try { return readFileSync(join(root, 'fake.log'), 'utf8') } catch { return '' } },
    done: () => rmSync(root, {recursive: true, force: true}),
  }
}

export const readJ = (f: string) => { try { return JSON.parse(readFileSync(f, 'utf8')) } catch { return null } }
export const writeJ = (f: string, v: unknown) => { mkdirSync(join(f, '..'), {recursive: true}); writeFileSync(f, JSON.stringify(v)) }
