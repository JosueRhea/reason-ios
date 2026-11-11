// Reason push relay: Reason event webhooks in, APNs pushes out.
//
//   POST   /v1/devices          Bearer <Reason key>  {token, env}   register this phone (creates the webhook once)
//   DELETE /v1/devices/:token   Bearer <Reason key>                 forget it
//   POST   /v1/test             Bearer <Reason key>                 push a test notification to every phone
//   POST   /v1/hook/:org        Standard Webhooks signed            Reason event → notification
//
// KV: org:<org> = {key, hook: {id, secret}}, devs:<org> = [{token, env}], seen:<webhook-id>, reason:<id>.
// The workspace key is kept so the relay can read the finished turn and write a useful notification.

const API = 'https://api.reasonmachines.com/v3'
const EVENTS = ['turn.finished', 'input_request.created']

export default {
  async fetch(req, env, ctx) {
    const { pathname } = new URL(req.url)
    try {
      if (req.method === 'POST' && pathname === '/v1/devices') return await register(req, env)
      if (req.method === 'DELETE' && pathname.startsWith('/v1/devices/')) return await unregister(req, env, pathname.slice(12))
      if (req.method === 'POST' && pathname === '/v1/test') return await test(req, env)
      const m = pathname.match(/^\/v1\/hook\/([0-9a-f-]{36})$/)
      if (req.method === 'POST' && m) return await hook(req, env, ctx, m[1])
      return json({ error: 'not found' }, 404)
    } catch (e) {
      return json({ error: String(e?.message || e) }, e?.status || 500)
    }
  },
}

// ---------------------------------------------------------------- devices

async function caller(req) {
  const key = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '')
  if (!key) throw httpError(401, 'missing key')
  const me = await reason(key, 'GET', '/self')
  return { key, org: me.org_id }
}

async function register(req, env) {
  const { key, org } = await caller(req)
  const body = await req.json()
  if (!/^[0-9a-f]{64,200}$/i.test(body.token || '')) throw httpError(400, 'bad token')
  const devEnv = body.env === 'production' ? 'production' : 'sandbox'

  const rec = (await env.KV.get(`org:${org}`, 'json')) || {}
  rec.key = key
  if (rec.hook) {
    // Still there and active? (It is disabled after 3 days of failed deliveries, or may have been deleted.)
    const h = await reason(key, 'GET', `/organizations/${org}/event-webhooks/${rec.hook.id}`).catch(() => null)
    if (!h || h.status !== 'active') {
      if (h) await reason(key, 'DELETE', `/organizations/${org}/event-webhooks/${rec.hook.id}`).catch(() => {})
      rec.hook = null
    }
  }
  if (!rec.hook) {
    const origin = new URL(req.url).origin
    const h = await reason(key, 'POST', `/organizations/${org}/event-webhooks`, {
      url: `${origin}/v1/hook/${org}`, description: 'Reason for iPhone: push notifications', event_types: EVENTS,
    })
    rec.hook = { id: h.id, secret: h.secret }
  }
  await env.KV.put(`org:${org}`, JSON.stringify(rec))

  const devs = ((await env.KV.get(`devs:${org}`, 'json')) || []).filter(d => d.token !== body.token)
  devs.push({ token: body.token, env: devEnv, at: Date.now() })
  await env.KV.put(`devs:${org}`, JSON.stringify(devs.slice(-10)))
  return json({ ok: true, devices: devs.length, webhook: rec.hook.id })
}

async function unregister(req, env, token) {
  const { org } = await caller(req)
  const devs = ((await env.KV.get(`devs:${org}`, 'json')) || []).filter(d => d.token !== token)
  await env.KV.put(`devs:${org}`, JSON.stringify(devs))
  return json({ ok: true, devices: devs.length })
}

async function test(req, env) {
  const { org } = await caller(req)
  const sent = await pushAll(env, org, {
    aps: { alert: { title: 'Reason', body: 'Notifications are on. You\'ll hear from your Reasons here.' }, sound: 'default', 'mutable-content': 1 },
    kind: 'test',
  })
  return json({ ok: true, sent })
}

// ---------------------------------------------------------------- webhook

async function hook(req, env, ctx, org) {
  const raw = await req.text()
  const rec = await env.KV.get(`org:${org}`, 'json')
  if (!rec?.hook) return json({ error: 'unknown workspace' }, 404)
  const id = req.headers.get('webhook-id'), ts = req.headers.get('webhook-timestamp')
  if (!(await verify(rec.hook.secret, id, ts, req.headers.get('webhook-signature') || '', raw))) return json({ error: 'bad signature' }, 401)
  if (Math.abs(Date.now() / 1000 - Number(ts)) > 600) return json({ error: 'stale' }, 401)
  if (await env.KV.get(`seen:${id}`)) return json({ ok: true, duplicate: true })
  await env.KV.put(`seen:${id}`, '1', { expirationTtl: 86400 })

  const ev = JSON.parse(raw)
  // Answer fast; build and send the notification after.
  ctx.waitUntil(handle(env, org, rec.key, ev).catch(e => console.log('handle failed', ev.type, e?.message)))
  return json({ ok: true })
}

async function handle(env, org, key, ev) {
  const sid = ev.session_id
  if (!sid) return
  const s = await reason(key, 'GET', `/organizations/${org}/sessions/${sid}?fields=title,status,outcome,result_summary,error_message,reason_id,created_by_session_id`)
  const r = s.reason_id ? await reasonInfo(env, key, org, s.reason_id) : null

  if (ev.type === 'turn.finished') {
    const status = ev.data?.status
    if (status === 'suspended' || status === 'running') return            // still going (waiting on children or input)
    if (s.created_by_session_id) return                                    // a child: its parent reports back
    if (s.outcome === 'cancelled' || status === 'cancelled') return        // you stopped it
    const failed = s.outcome === 'failure' || status === 'error' || status === 'failed'
    let body = plain(s.result_summary || '')
    if (failed) body = body || plain(s.error_message || '') || 'The turn stopped with an error.'
    if (!body) return
    await pushAll(env, org, {
      aps: {
        alert: r ? { title: r.name, body } : { title: s.title || 'Session', body },
        sound: 'default', 'thread-id': s.reason_id || sid, 'mutable-content': 1,
        'interruption-level': 'active', 'relevance-score': failed ? 0.8 : 0.6,
      },
      kind: failed ? 'failed' : 'reply', session_id: sid, reason_id: s.reason_id || null,
      reason: r, session_title: s.title || null,
    }, `turn-${ev.run_id || sid}`)
    return
  }

  if (ev.type === 'input_request.created') {
    const rid = ev.data?.request_id
    const ir = await reason(key, 'GET', `/organizations/${org}/sessions/${sid}/input-requests/${rid}`).catch(() => null)
    if (ir && ir.status && ir.status !== 'pending') return
    const type = ir?.type || ev.data?.type
    const label = plain(ir?.label || '') || ({ secret: 'Needs a secret', network_hosts: 'Wants network access', question: 'Has a question' })[type] || 'Needs your input'
    const hosts = ir?.network_hosts?.hosts
    const body = hosts?.length ? `${label}\n${hosts.join(', ')}` : (ir?.reason ? `${label}\n${plain(ir.reason)}` : label)
    const approvable = (ir?.actions || []).includes('approve') && (ir?.actions || []).includes('deny')
    const child = s.created_by_session_id ? (s.title || 'a Session') : null
    await pushAll(env, org, {
      aps: {
        alert: { title: r ? r.name : (s.title || 'Session'), ...(r && child ? { subtitle: child } : {}), body },
        sound: 'default', 'thread-id': s.reason_id || sid, 'mutable-content': 1,
        'interruption-level': 'time-sensitive', 'relevance-score': 1,
        category: approvable ? 'REQUEST_APPROVE' : 'REQUEST_OPEN',
      },
      kind: 'request', session_id: sid, reason_id: s.reason_id || null, request_id: rid, request_type: type,
      reason: r, session_title: s.title || null,
    }, `req-${rid}`)
  }
}

async function reasonInfo(env, key, org, id) {
  const cached = await env.KV.get(`reason:${id}`, 'json')
  if (cached) return cached
  const r = await reason(key, 'GET', `/organizations/${org}/reasons/${id}`).catch(() => null)
  if (!r) return null
  const info = { id, name: r.name, color: r.appearance?.color || null, eyes: r.appearance?.eyes || null }
  await env.KV.put(`reason:${id}`, JSON.stringify(info), { expirationTtl: 3600 })
  return info
}

// Markdown → one readable paragraph for a lock screen.
function plain(s) {
  return s.replace(/```[\s\S]*?```/g, ' ')
    .replace(/!\[[^\]]*\]\([^)]*\)/g, '')
    .replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
    .replace(/<\/?[a-z_]+>/gi, '')
    .replace(/[*_`#>]+/g, '')
    .replace(/\s+/g, ' ').trim().slice(0, 900)
}

// ---------------------------------------------------------------- APNs

async function pushAll(env, org, payload, collapseId) {
  const devs = (await env.KV.get(`devs:${org}`, 'json')) || []
  if (!devs.length) return 0
  const jwt = await apnsToken(env)
  const dead = []
  let sent = 0
  await Promise.all(devs.map(async d => {
    const host = d.env === 'production' ? 'api.push.apple.com' : 'api.sandbox.push.apple.com'
    const headers = { authorization: `bearer ${jwt}`, 'apns-topic': env.APNS_TOPIC, 'apns-push-type': 'alert', 'apns-priority': '10' }
    if (collapseId) headers['apns-collapse-id'] = collapseId.slice(0, 64)
    const res = await fetch(`https://${host}/3/device/${d.token}`, { method: 'POST', headers, body: JSON.stringify(payload) })
    if (res.ok) { sent++; return }
    const why = (await res.json().catch(() => ({}))).reason
    console.log('apns', res.status, why)
    if (res.status === 410 || why === 'BadDeviceToken' || why === 'Unregistered') dead.push(d.token)
  }))
  if (dead.length) await env.KV.put(`devs:${org}`, JSON.stringify(devs.filter(d => !dead.includes(d.token))))
  return sent
}

let cachedJwt = null
async function apnsToken(env) {
  if (cachedJwt && Date.now() - cachedJwt.at < 40 * 60 * 1000) return cachedJwt.token
  const pem = env.APNS_KEY.replace(/-----[^-]+-----/g, '').replace(/\s+/g, '')
  const key = await crypto.subtle.importKey('pkcs8', b64decode(pem), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign'])
  const enc = o => b64url(new TextEncoder().encode(JSON.stringify(o)))
  const unsigned = `${enc({ alg: 'ES256', kid: env.APNS_KEY_ID })}.${enc({ iss: env.APNS_TEAM, iat: Math.floor(Date.now() / 1000) })}`
  const sig = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, new TextEncoder().encode(unsigned))
  cachedJwt = { token: `${unsigned}.${b64url(new Uint8Array(sig))}`, at: Date.now() }
  return cachedJwt.token
}

// ---------------------------------------------------------------- helpers

async function verify(secret, id, ts, header, body) {
  if (!secret || !id || !ts) return false
  const key = await crypto.subtle.importKey('raw', b64decode(secret.replace(/^whsec_/, '')), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
  const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(`${id}.${ts}.${body}`))
  const expected = b64(new Uint8Array(mac))
  return header.split(' ').some(part => {
    const [v, sig] = part.split(',')
    return v === 'v1' && sig && timingSafeEqual(sig, expected)
  })
}

function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false
  let x = 0
  for (let i = 0; i < a.length; i++) x |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return x === 0
}

async function reason(key, method, path, body) {
  const res = await fetch(API + path, {
    method, headers: { authorization: `Bearer ${key}`, 'content-type': 'application/json', accept: 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  })
  if (!res.ok) throw httpError(res.status === 401 || res.status === 403 ? res.status : 502, `Reason ${method} ${path.split('?')[0]}: ${res.status}`)
  return res.status === 204 ? {} : res.json()
}

const b64decode = s => Uint8Array.from(atob(s), c => c.charCodeAt(0))
const b64 = bytes => btoa(String.fromCharCode(...bytes))
const b64url = bytes => b64(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
const json = (o, status = 200) => new Response(JSON.stringify(o), { status, headers: { 'content-type': 'application/json' } })
const httpError = (status, message) => Object.assign(new Error(message), { status })
