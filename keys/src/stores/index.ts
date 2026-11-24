import type {Profile} from '../profile'
import {claudeStore} from './claude'
import {codexStore} from './codex'
import {agyStore, ampStore, grokStore, opencodeStore} from './others'
import {piStore} from './pi'
import type {Store} from './store'

export type {Store} from './store'

export function storeFor(p: Profile): Store {
  switch (p.harness) {
    case 'claude': return claudeStore(p)
    case 'codex': return codexStore(p)
    case 'pi': return piStore(p)
    case 'agy': return agyStore(p)
    case 'amp': return ampStore(p)
    case 'grok': return grokStore(p)
    case 'opencode': return opencodeStore(p)
  }
}
