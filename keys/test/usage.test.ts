import {expect, test} from 'bun:test'
import {agyPlan, agyReportGroups, agyWindows, claudePlan, claudeWindows, codexPlan, codexWindows} from '../src/usage'

test('Claude: limits, with the older fields only where limits leave a window out', () => {
  const j = {
    five_hour: null,
    seven_day: {utilization: 31, resets_at: '2026-11-28T23:00:00.168316+00:00'},
    limits: [
      {kind: 'weekly_all', group: 'weekly', percent: 31, resets_at: '2026-11-28T23:00:00.168316+00:00', scope: null, is_active: true},
      {kind: 'weekly_scoped', group: 'weekly', percent: 0, resets_at: '2026-11-28T23:00:00+00:00', scope: {model: {id: null, display_name: 'Fable'}}, is_active: false},
    ],
  }
  expect(claudeWindows(j)).toEqual([
    {label: 'Week', percent: 31, resetsAt: Date.parse('2026-11-28T23:00:00.168316+00:00')},
    {label: 'Week · Fable', percent: 0, resetsAt: Date.parse('2026-11-28T23:00:00+00:00')},
  ])
  expect(claudeWindows({five_hour: {utilization: 12.4, resets_at: '2026-11-24T20:00:00Z'}, seven_day: {utilization: 50, resets_at: null}})).toEqual([
    {label: '5 hours', percent: 12, resetsAt: Date.parse('2026-11-24T20:00:00Z')},
    {label: 'Week', percent: 50, resetsAt: null},
  ])
  expect(claudePlan({subscriptionType: 'max', rateLimitTier: 'default_claude_max_20x'})).toBe('Max 20x')
  expect(claudePlan({subscriptionType: 'pro'})).toBe('Pro')
})

test('Codex: its windows, named by their length', () => {
  const j = {plan_type: 'promax', rate_limit: {primary_window: {used_percent: 59, limit_window_seconds: 604800, reset_after_seconds: 2782, reset_at: 1795541728}, secondary_window: null}}
  expect(codexWindows(j)).toEqual([{label: 'Week', percent: 59, resetsAt: 1795541728000}])
  expect(codexWindows({rate_limit: {primary_window: {used_percent: 3, limit_window_seconds: 18000, reset_at: 1}}})[0].label).toBe('5 hours')
  expect(codexPlan(j)).toBe('Pro Max')
})

test('agy: one window per model family, the least left', () => {
  const j = {models: {
    chat_1: {quotaInfo: {remainingFraction: 0}, isInternal: true},
    a: {displayName: 'Gemini 4 Neon', modelProvider: 'MODEL_PROVIDER_GOOGLE', quotaInfo: {remainingFraction: 0.8, resetTime: '2026-11-24T21:49:41Z'}},
    b: {displayName: 'Gemini Flash', modelProvider: 'MODEL_PROVIDER_GOOGLE', quotaInfo: {remainingFraction: 0.25, resetTime: '2026-11-24T22:00:00Z'}},
    c: {displayName: 'Claude Opus', modelProvider: 'MODEL_PROVIDER_ANTHROPIC', quotaInfo: {remainingFraction: 1, resetTime: '2026-11-24T21:49:41Z'}},
  }}
  expect(agyWindows(j)).toEqual([
    {label: 'Gemini', percent: 75, resetsAt: Date.parse('2026-11-24T22:00:00Z')},
    {label: 'Claude', percent: 0, resetsAt: Date.parse('2026-11-24T21:49:41Z')},
  ])
  // With agy's quota summary: its groups' limits, and Gemini's 5-hour limit from its models.
  const summary = {groups: [{displayName: 'Claude and GPT models', buckets: [
    {bucketId: '3p-weekly', window: 'weekly', resetTime: '2026-12-02T16:33:33Z', remainingFraction: 0.9},
    {bucketId: '3p-5h', window: '5h', resetTime: '2026-11-25T21:33:33Z', remainingFraction: 1},
  ]}]}
  expect(agyWindows(j, summary)).toEqual([
    {label: 'Gemini · 5h', percent: 75, resetsAt: Date.parse('2026-11-24T22:00:00Z')},
    {label: 'Claude & GPT · Week', percent: 10, resetsAt: Date.parse('2026-12-02T16:33:33Z')},
    {label: 'Claude & GPT · 5h', percent: 0, resetsAt: Date.parse('2026-11-25T21:33:33Z')},
  ])
  // With agy's own report: Gemini's week too, its 5 hours live from the models.
  const report = agyReportGroups({status: 'SUCCESS', command: {name: 'usage', data: {groups: [
    {name: 'Gemini Models', buckets: [{id: 'gemini-weekly', window: 'weekly', remaining_fraction: 0.95, reset_time: '2026-12-01T02:05:21Z'}, {id: 'gemini-5h', window: '5h', remaining_fraction: 0.5, reset_time: '2026-11-25T19:24:26Z'}]},
  ]}}})
  expect(agyWindows(j, {groups: [...report, ...summary.groups]}).map(w => [w.label, w.percent])).toEqual([
    ['Gemini · Week', 5], ['Gemini · 5h', 75], ['Claude & GPT · Week', 10], ['Claude & GPT · 5h', 0],
  ])
  expect(agyReportGroups({status: 'FAILED'})).toEqual([])
  expect(agyPlan({currentTier: {id: 'free-tier', name: 'Antigravity'}})).toBe('Free')
  expect(agyPlan({paidTier: {id: 'g1-ultra-tier', name: 'Google AI Ultra'}, currentTier: {id: 'standard-tier'}})).toBe('Google AI Ultra')
})
