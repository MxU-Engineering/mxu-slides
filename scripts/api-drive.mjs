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
  console.error('Usage: node scripts/api-drive.mjs --token mxu_… [--port 6980]')
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
    headers: {
      Authorization: `Bearer ${TOKEN}`,
      'Content-Type': 'application/json',
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  const text = await response.text()
  let json
  try {
    json = JSON.parse(text)
  } catch {
    json = null
  }
  if (!response.ok) {
    throw new Error(`${method} ${path} → ${response.status}: ${text}`)
  }
  return json
}

const slide = (id, line) => ({
  id: `${id}`,
  name: '',
  objects: [{ id: `${id}-text`, objectKind: 'text', name: 'Lyrics', text: line }],
})

console.log('discovery')
const ping = await (await fetch(`${BASE}/v1/ping`)).json()
ok('ping answers unauthenticated', ping.product === 'MxU Slides')

const openapi = await (await fetch(`${BASE}/openapi.json`)).json()
ok('OpenAPI document serves', openapi.openapi === '3.1.0')
ok('contract covers the show endpoints', Boolean(openapi.paths['/v1/show/slide']))
ok('document schemas ride the same source as the app models',
  Boolean(openapi.components.schemas.Presentation))

const asyncapi = await (await fetch(`${BASE}/asyncapi.json`)).json()
ok('AsyncAPI document serves', Boolean(asyncapi.channels.show))

const denied = await fetch(`${BASE}/v1/status`)
ok('missing token is rejected', denied.status === 401)

console.log('create/edit')
const created = await api('POST', '/v1/documents/presentations', {
  name: 'API Drive Song',
  presentationKind: 'deck',
  themeId: '',
  slides: [slide('s1', 'Verse one from the API'),
           slide('s2', 'Chorus from the API'),
           slide('s3', 'Verse two from the API')],
})
const presentationId = created.id
ok('presentation created', Boolean(presentationId))

const fetched = await api('GET', `/v1/documents/presentations/${presentationId}`)
ok('created presentation round-trips with 3 slides', fetched.slides.length === 3)

const service = await api('POST', '/v1/documents/services', {
  name: 'API Drive Service',
  serviceDate: new Date().toISOString().slice(0, 10),
  items: [],
})
ok('service created', Boolean(service.id))

await api('POST', `/v1/services/${service.id}/items`, { refId: presentationId })
const serviceDoc = await api('GET', `/v1/documents/services/${service.id}`)
ok('run order holds the presentation', serviceDoc.items.length === 1
  && serviceDoc.items[0].refId === presentationId)
const itemId = serviceDoc.items[0].id

console.log('control')
await api('POST', `/v1/services/${service.id}/select`)
await api('POST', '/v1/show/slide', { serviceItemId: itemId, occurrence: 0 })
let status = await api('GET', '/v1/status')
ok('slide 1 is live', status.liveSlide?.slideId === 's1'
  && status.liveSlide?.serviceItemId === itemId)
ok('confidence NEXT reads slide 2', (status.nextSlideText ?? '').includes('Chorus'))

await api('POST', '/v1/show/advance', { steps: 1 })
await api('POST', '/v1/show/advance', { steps: 1 })
status = await api('GET', '/v1/status')
ok('two advances land on slide 3', status.liveSlide?.slideId === 's3')

await api('POST', '/v1/show/advance', { steps: -1 })
status = await api('GET', '/v1/status')
ok('advance -1 steps back to slide 2', status.liveSlide?.slideId === 's2')

await api('POST', '/v1/alerts/fire', {
  message: 'Car lights on — API test', behavior: 'persist', target: 'confidence',
})
status = await api('GET', '/v1/status')
ok('alert is on air', status.alert?.message.includes('Car lights'))
await api('POST', '/v1/alerts/dismiss')

await api('POST', '/v1/show/clear', { function: 'slides' })
status = await api('GET', '/v1/status')
ok('Clear Function: Slides drops the slide', status.liveSlide == null)
await api('POST', '/v1/show/clear-all')

console.log('view')
const summary = await api('GET', '/v1/library')
ok('library summary counts kinds', typeof summary.counts.presentations === 'number')
const entries = await api('GET', '/v1/library/presentations')
ok('library listing shows the creation', entries.some((entry) => entry.id === presentationId))
for (const path of ['/v1/timers', '/v1/audio', '/v1/transport', '/v1/outputs']) {
  await api('GET', path)
}
ok('timers/audio/transport/outputs all answer', true)

console.log('websocket')
await new Promise((resolve, reject) => {
  const timeout = setTimeout(() => reject(new Error('WebSocket timed out')), 8000)
  const socket = new WebSocket(`ws://${HOST}:${PORT}/v1/ws?token=${TOKEN}`)
  let sawEvent = false
  let sawResult = false
  socket.onmessage = (message) => {
    const frame = JSON.parse(message.data)
    if (frame.type === 'hello') {
      socket.send(JSON.stringify({ type: 'subscribe', topics: ['show'] }))
    } else if (frame.type === 'subscribed') {
      socket.send(JSON.stringify({
        type: 'command', id: 'c1', method: 'POST', path: '/v1/show/slide',
        body: { serviceItemId: itemId, occurrence: 0 },
      }))
    } else if (frame.type === 'result' && frame.id === 'c1') {
      sawResult = frame.status === 200
      if (sawEvent && sawResult) finish()
    } else if (frame.type === 'event' && frame.topic === 'show') {
      sawEvent = frame.data.liveSlide?.slideId === 's1'
      if (sawEvent && sawResult) finish()
    }
  }
  socket.onerror = (error) => reject(new Error(`WebSocket error: ${error.message ?? error}`))
  function finish() {
    clearTimeout(timeout)
    socket.close()
    ok('WS command fires a slide', sawResult)
    ok('WS subscription pushes the state change', sawEvent)
    resolve()
  }
})
await api('POST', '/v1/show/clear-all')

if (!KEEP) {
  await api('DELETE', `/v1/documents/services/${service.id}`)
  await api('DELETE', `/v1/documents/presentations/${presentationId}`)
  const gone = await fetch(`${BASE}/v1/documents/presentations/${presentationId}`, {
    headers: { Authorization: `Bearer ${TOKEN}` },
  })
  ok('cleanup deletes what the script created', gone.status === 404)
}

console.log(`\nAPI drive: ${passed} checks passed.`)
