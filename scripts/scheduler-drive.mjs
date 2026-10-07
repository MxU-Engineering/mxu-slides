#!/usr/bin/env node

const args = process.argv.slice(2)
function arg(name, fallback) {
  const index = args.indexOf(`--${name}`)
  return index >= 0 ? args[index + 1] : fallback
}
const TOKEN = arg('token')
const PORT = arg('port', '6980')
const FAST = args.includes('--fast')
const BASE = `http://localhost:${PORT}`

if (!TOKEN) {
  console.error('Usage: node scripts/scheduler-drive.mjs --token mxu_… [--port 6980] [--fast]')
  process.exit(2)
}

let passed = 0
function ok(label, condition, detail = '') {
  if (condition) {
    passed += 1
    console.log(`  ✓ ${label}`)
  } else {
    console.error(`  ✗ ${label} ${detail}`)
    process.exit(1)
  }
}

async function api(method, path, body) {
  const response = await fetch(`${BASE}${path}`, {
    method,
    headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  const text = await response.text()
  if (!response.ok) throw new Error(`${method} ${path} → ${response.status}: ${text}`)
  return text ? JSON.parse(text) : null
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
const uuid = () => crypto.randomUUID()

function localMinuteString(date) {
  const pad = (n) => String(n).padStart(2, '0')
  return (
    `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}` +
    `T${pad(date.getHours())}:${pad(date.getMinutes())}`
  )
}

async function triggerStatus(id) {
  const status = await api('GET', '/v1/scheduler')
  return status.triggers.find((t) => t.id === id)
}

async function pollUntil(label, timeoutMs, probe) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const value = await probe()
    if (value) return value
    await sleep(1000)
  }
  throw new Error(`timed out waiting for ${label}`)
}

const initial = await api('GET', '/v1/scheduler')
console.log(`Scheduler reachable — on=${initial.enabled}, ${initial.triggers.length} trigger(s)`)

console.log('\n1. Trigger CRUD')
const oneTimeID = uuid()

const due = new Date(Math.ceil((Date.now() + 60_000) / 60_000) * 60_000)
await api('POST', '/v1/documents/schedule-triggers', {
  id: oneTimeID,
  name: 'Drive — one-time',
  conditions: [{ id: uuid(), kind: 'oneTime', date: localMinuteString(due) }],
  actions: [{ id: uuid(), kind: 'clearAll' }],
})
let row = await triggerStatus(oneTimeID)
ok('created trigger appears in scheduler status', row && row.enabled && row.folderEnabled)

console.log('\n2. Run Now')

await api('POST', '/v1/scheduler/enabled', { enabled: false })
await api('POST', `/v1/scheduler/triggers/${oneTimeID}/fire`)
row = await triggerStatus(oneTimeID)
ok(
  'Run Now records a firing while the Scheduler is OFF (gates ignored by design)',
  row.lastFired && Date.now() - new Date(row.lastFired).getTime() < 5000
)

console.log('\n3. Gates')
await api('POST', '/v1/scheduler/enabled', { enabled: true })
let status = await api('GET', '/v1/scheduler')
ok('turning the Scheduler on via API sticks', status.enabled === true)
ok(
  'on: the one-time due shows as next fire',
  status.nextFire && status.nextFire.triggerId === oneTimeID
)
await api('POST', `/v1/scheduler/triggers/${oneTimeID}/enabled`, { enabled: false })
status = await api('GET', '/v1/scheduler')
ok(
  'pausing the trigger clears it from next fire',
  !status.nextFire || status.nextFire.triggerId !== oneTimeID
)
await api('POST', `/v1/scheduler/triggers/${oneTimeID}/enabled`, { enabled: true })
status = await api('GET', '/v1/scheduler')
ok(
  're-enabling restores next fire',
  status.nextFire && status.nextFire.triggerId === oneTimeID
)

console.log('\n4. Timer crossing')
const timers = await api('GET', '/v1/timers')
const countdown = timers.find((t) => t.mode === 'countdown' && t.displaySeconds >= 10)
let timerTriggerID = null
if (!countdown) {
  console.log('  (skipped — no countdown timer ≥10s in the room)')
} else {
  timerTriggerID = uuid()
  await api('POST', '/v1/documents/schedule-triggers', {
    id: timerTriggerID,
    name: 'Drive — timer crossing',
    conditions: [
      {
        id: uuid(),
        kind: 'timerReaches',
        timerId: countdown.id,
        timerSeconds: countdown.displaySeconds - 5,
      },
    ],
    actions: [{ id: uuid(), kind: 'clearAll' }],
  })
  await api('POST', `/v1/timers/${countdown.id}/reset`)
  await api('POST', `/v1/timers/${countdown.id}/play`)
  const fired = await pollUntil('timer-crossing fire', 20_000, () =>
    triggerStatus(timerTriggerID).then((t) => t.lastFired)
  )
  ok(`"${countdown.name}" crossing fired the trigger`, Boolean(fired))
  await api('POST', `/v1/timers/${countdown.id}/reset`)
}

if (FAST) {
  console.log('\n5. Scheduled fire — skipped (--fast)')
} else {
  console.log(`\n5. Scheduled fire (due ${due.toLocaleTimeString()}, waiting…)`)
  const before = (await triggerStatus(oneTimeID)).lastFired
  const fired = await pollUntil(
    'the scheduled fire',
    due.getTime() - Date.now() + 30_000,
    async () => {
      const t = await triggerStatus(oneTimeID)
      return t.lastFired && t.lastFired !== before ? t.lastFired : null
    }
  )
  const drift = Math.abs(new Date(fired).getTime() - due.getTime())
  ok(`fired at its moment (drift ${Math.round(drift / 1000)}s ≤ grace)`, drift < 60_000)
  status = await api('GET', '/v1/scheduler')
  ok(
    'a consumed one-time never re-matches (no next fire from it)',
    !status.nextFire || status.nextFire.triggerId !== oneTimeID
  )
}

console.log('\n6. Cleanup')
await api('POST', '/v1/scheduler/enabled', { enabled: initial.enabled })
await api('DELETE', `/v1/documents/schedule-triggers/${oneTimeID}`)
if (timerTriggerID) await api('DELETE', `/v1/documents/schedule-triggers/${timerTriggerID}`)
status = await api('GET', '/v1/scheduler')
ok(
  'test triggers deleted, on/off switch restored',
  status.enabled === initial.enabled &&
    !status.triggers.some((t) => t.id === oneTimeID || t.id === timerTriggerID)
)

console.log(`\nAll ${passed} checks passed.`)
