#!/usr/bin/env node

const args = process.argv.slice(2)
function arg(name, fallback) {
  const index = args.indexOf(`--${name}`)
  return index >= 0 ? args[index + 1] : fallback
}
const TOKEN = arg('token')
const PORT = arg('port', '6980')
const HOST = arg('host', 'localhost')
const KEEP = args.includes('--keep')
const BASE = `http://${HOST}:${PORT}`

if (!TOKEN) {
  console.error('Usage: node scripts/animation-drive.mjs --token mxu_… [--port 6980] [--keep]')
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
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

async function api(method, path, body) {
  const response = await fetch(`${BASE}${path}`, {
    method,
    headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  const text = await response.text()
  let json = null
  try { json = JSON.parse(text) } catch {}
  if (!response.ok) throw new Error(`${method} ${path} → ${response.status}: ${text}`)
  return json
}

const step = (id, extra) => ({
  id, kind: 'in', animation: 'fade', trigger: 'onClick', durationSeconds: 0.5, ...extra,
})

const pointsSlide = {
  id: 'bd-points',
  name: 'Three points',
  objects: [{
    id: 'bd-points-text', objectKind: 'text', name: 'Points',
    text: 'Grace comes first\nFaith answers\nLove remains',
    x: 160, y: 200, width: 1600, height: 680,
    animationSteps: [
      step('bd-p1', { ranges: [{ line: 0, column: 0, length: 17 }], animation: 'move', offsetX: -120, withFade: true }),
      step('bd-p2', { ranges: [{ line: 1, column: 0, length: 13 }], animation: 'move', offsetX: -120, withFade: true }),
      step('bd-p3', { ranges: [{ line: 2, column: 0, length: 12 }], animation: 'move', offsetX: -120, withFade: true }),
    ],
  }],
}
const blankSlide = {
  id: 'bd-blank',
  name: 'Fill in the blank',
  objects: [{
    id: 'bd-blank-text', objectKind: 'text', name: 'Blank',
    text: 'Faith is the ______ of things hoped for',
    x: 160, y: 380, width: 1600, height: 320,
    animationSteps: [
      { id: 'bd-b1', kind: 'in', animation: 'scale', trigger: 'onClick', durationSeconds: 0.4,
        fromScale: 1.3, withFade: true, placeholderUnderline: true,
        ranges: [{ line: 0, column: 13, length: 6 }] },
    ],
  }],
}
const exitStep = (id, line, length) => step(id, {
  ranges: [{ line, column: 0, length }], animation: 'move', offsetX: -120, withFade: true,
})

const exitSlide = {
  id: 'bd-exit',
  name: 'Exit group',
  autoAdvance: { delaySeconds: 3 },
  objects: [{
    id: 'bd-exit-text', objectKind: 'text', name: 'Exit points',
    text: 'First\nSecond\nThird',
    x: 160, y: 200, width: 1600, height: 680,
    animationSteps: [
      exitStep('bd-x1', 0, 5), exitStep('bd-x2', 1, 6), exitStep('bd-x3', 2, 5),
      { id: 'bd-x-out', kind: 'out', animation: 'fade', trigger: 'onDismiss', durationSeconds: 0.3 },
    ],
  }],
}
const finalSlide = {
  id: 'bd-final',
  name: 'After the exit',
  objects: [{ id: 'bd-final-text', objectKind: 'text', name: 'Text', text: 'The fifth Advance landed here' }],
}

const afterSlide = {
  id: 'bd-after',
  name: 'Next slide',
  objects: [{ id: 'bd-after-text', objectKind: 'text', name: 'Text', text: 'The fourth Advance landed here' }],
}

const lowerThird = {
  name: 'Animation Lower Third',
  animationOrder: ['bd-plate-in', 'bd-name-in', 'bd-name-out', 'bd-plate-out'],
  objects: [
    {
      id: 'bd-plate', objectKind: 'shape', name: 'Plate', text: '',
      x: 120, y: 820, width: 900, height: 140,
      fill: { fillKind: 'solid', colorHex: '#1E3A8AFF' },
      animationSteps: [
        { id: 'bd-plate-in', kind: 'in', animation: 'move', trigger: 'withPrevious', durationSeconds: 0.6, edge: 'left' },
        { id: 'bd-plate-out', kind: 'out', animation: 'move', trigger: 'afterPrevious', durationSeconds: 0.5, edge: 'left' },
      ],
    },
    {
      id: 'bd-name', objectKind: 'text', name: 'Name', text: 'Pastor Anna Reyes',
      x: 150, y: 840, width: 840, height: 100,
      animationSteps: [
        { id: 'bd-name-in', kind: 'in', animation: 'fade', trigger: 'afterPrevious', delaySeconds: 0.15, durationSeconds: 0.4 },
        { id: 'bd-name-out', kind: 'out', animation: 'fade', trigger: 'onDismiss', durationSeconds: 0.3 },
      ],
    },
  ],
}

console.log('create')
const presentation = await api('POST', '/v1/documents/presentations', {
  name: 'Animation Demo', presentationKind: 'deck', themeId: '',
  slides: [pointsSlide, blankSlide, afterSlide, exitSlide, finalSlide],
})
ok('Animation Demo presentation created', Boolean(presentation.id))
const overlay = await api('POST', '/v1/documents/overlays', lowerThird)
ok('Animation Lower Third overlay created', Boolean(overlay.id))
const fetched = await api('GET', `/v1/documents/presentations/${presentation.id}`)
ok('animation steps round-trip through the document endpoint',
  fetched.slides[0].objects[0].animationSteps?.length === 3)

console.log('slide animation steps')
await api('POST', '/v1/show/slide', { presentationId: presentation.id, slideIndex: 0 })
let status = await api('GET', '/v1/status')
ok('points slide is live with 0/3 revealed',
  status.liveSlide?.slideId === 'bd-points' && status.liveSlide?.stepIndex === 0 && status.liveSlide?.stepCount === 3,
  JSON.stringify(status.liveSlide))
for (let i = 1; i <= 3; i += 1) {
  await api('POST', '/v1/show/advance', { steps: 1 })
  status = await api('GET', '/v1/status')
  ok(`advance ${i} reveals point ${i} (${status.liveSlide?.stepIndex}/${status.liveSlide?.stepCount})`,
    status.liveSlide?.slideId === 'bd-points' && status.liveSlide?.stepIndex === i)
}
await api('POST', '/v1/show/advance', { steps: -1 })
status = await api('GET', '/v1/status')
ok('back un-reveals one point before leaving the slide',
  status.liveSlide?.slideId === 'bd-points' && status.liveSlide?.stepIndex === 2)
await api('POST', '/v1/show/advance', { steps: 1 })
await api('POST', '/v1/show/advance', { steps: 1 })
status = await api('GET', '/v1/status')
ok('the fourth advance moves to the next slide (fill-in-the-blank, 0/1)',
  status.liveSlide?.slideId === 'bd-blank' && status.liveSlide?.stepIndex === 0 && status.liveSlide?.stepCount === 1)
await api('POST', '/v1/show/advance', { steps: 1 })
await api('POST', '/v1/show/advance', { steps: 1 })
status = await api('GET', '/v1/status')
ok('blank filled, then the slide without animation steps', status.liveSlide?.slideId === 'bd-after'
  && status.liveSlide?.stepIndex == null)

console.log('exit semantics')
await api('POST', '/v1/show/slide', { presentationId: presentation.id, slideIndex: 3 })
status = await api('GET', '/v1/status')
ok('exit slide is live with 0/4 (3 clicks + the exit press)',
  status.liveSlide?.slideId === 'bd-exit' && status.liveSlide?.stepIndex === 0 && status.liveSlide?.stepCount === 4,
  JSON.stringify(status.liveSlide))
for (let i = 1; i <= 3; i += 1) await api('POST', '/v1/show/advance', { steps: 1 })
status = await api('GET', '/v1/status')
ok('three advances consume the clicks (3/4)', status.liveSlide?.stepIndex === 3)
await api('POST', '/v1/show/advance', { steps: 1 })
status = await api('GET', '/v1/status')
ok('the 4th advance plays the exit while the CUE STAYS LIVE (4/4)',
  status.liveSlide?.slideId === 'bd-exit' && status.liveSlide?.stepIndex === 4)
await api('POST', '/v1/show/advance', { steps: -1 })
status = await api('GET', '/v1/status')
ok('back un-plays the exit (3/4, content returns)',
  status.liveSlide?.slideId === 'bd-exit' && status.liveSlide?.stepIndex === 3)
await api('POST', '/v1/show/advance', { steps: 1 })
await api('POST', '/v1/show/advance', { steps: 1 })
status = await api('GET', '/v1/status')
ok('the advance after the exit press fires the next slide',
  status.liveSlide?.slideId === 'bd-final')

await api('POST', '/v1/show/slide', { presentationId: presentation.id, slideIndex: 3 })
for (let i = 1; i <= 4; i += 1) await api('POST', '/v1/show/advance', { steps: 1 })
await api('POST', '/v1/show/slide', { presentationId: presentation.id, slideIndex: 4 })
status = await api('GET', '/v1/status')
ok('a direct fire mid-exit cuts to the fired slide', status.liveSlide?.slideId === 'bd-final')

await api('POST', '/v1/show/slide', { presentationId: presentation.id, slideIndex: 3 })
await api('POST', '/v1/show/advance', { steps: 1, settled: true })
status = await api('GET', '/v1/status')
ok('settled advance skips the steps and fires the next slide',
  status.liveSlide?.slideId === 'bd-final')

await api('POST', '/v1/show/slide', { presentationId: presentation.id, slideIndex: 3 })
await sleep(4000)
status = await api('GET', '/v1/status')
ok('Auto Advance waits while human steps are pending (still 0/4 after 4s)',
  status.liveSlide?.slideId === 'bd-exit' && status.liveSlide?.stepIndex === 0)
for (let i = 1; i <= 4; i += 1) await api('POST', '/v1/show/advance', { steps: 1 })
let handed = false
for (let waited = 0; waited < 6000 && !handed; waited += 200) {
  await sleep(200)
  status = await api('GET', '/v1/status')
  handed = status.liveSlide?.slideId === 'bd-final'
}
ok('…then fires the next slide on its own after the exit lands + delay', handed)

console.log('overlay exit')
await api('POST', `/v1/overlays/${overlay.id}/fire`)
status = await api('GET', '/v1/status')
ok('lower third is live', status.overlays.some((o) => o.id === overlay.id))
await sleep(1500)
await api('POST', `/v1/overlays/${overlay.id}/dismiss`)
status = await api('GET', '/v1/status')
ok('dismiss keeps it up while the Out plays', status.overlays.some((o) => o.id === overlay.id))
let gone = false
for (let waited = 0; waited < 3000 && !gone; waited += 100) {
  await sleep(100)
  status = await api('GET', '/v1/status')
  gone = !status.overlays.some((o) => o.id === overlay.id)
}
ok('…and it disappears unaided once the Out lands (~0.8s)', gone)

await api('POST', `/v1/overlays/${overlay.id}/fire`)
await sleep(300)
await api('POST', '/v1/show/clear-all')
status = await api('GET', '/v1/status')
ok('Clear All cuts (no Out)', status.overlays.length === 0 && status.liveSlide == null)

if (KEEP) {
  console.log(`kept: presentation ${presentation.id}, overlay ${overlay.id}`)
} else {
  await api('DELETE', `/v1/documents/overlays/${overlay.id}`)
  await api('DELETE', `/v1/documents/presentations/${presentation.id}`)
  console.log('cleaned up')
}
console.log(`\n${passed} checks passed`)
