// Drive the real sidecar against ABS's documented item and per-episode progress
// routes. The upstream fixtures deliberately reject invented pagination/filter
// parameters and global progress requests.
import { test, before, beforeEach, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const SERVER = fileURLToPath(new URL('../server.js', import.meta.url));
const API_KEY = 'podcast-key._~+/-==';
const now = Math.floor(Date.now() / 1000);
const jwt = (name, expired = false) => `h.${Buffer.from(JSON.stringify({ exp: now + (expired ? -60 : 3600), sub: name })).toString('base64url')}.s`;
const active = jwt('active'), renewed = jwt('renewed'), early = jwt('revoked-before-expiry');
let upstream, side, base, work, sideError = '', fixture;
const calls = [];
const listen = server => new Promise(resolve => server.listen(0, '127.0.0.1', () => resolve(server.address().port)));
const episode = (id, publishedAt = 1700000000000, extra = {}) => ({
  id, title: id, publishedAt, audioFile: { ino: '1', duration: 60 }, ...extra,
});
const progress = (episodeId, isFinished = false, extra = {}) => ({
  libraryItemId: 'show', episodeId, currentTime: isFinished ? 60 : 12, duration: 60,
  lastUpdate: 1700000000000, isFinished, ...extra,
});
const defaultFixture = () => ({
  show: { id: 'show', mediaType: 'podcast', media: { metadata: { title: 'My show' }, episodes: [] } },
  rows: {},
});
const send = (res, body, status = 200) => res.writeHead(status, { 'Content-Type': 'application/json' }).end(JSON.stringify(body));
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));

before(async () => {
  work = mkdtempSync(join(tmpdir(), 'watchshelf-candidates-'));
  writeFileSync(join(work, 'sessions.json'), JSON.stringify({
    'active-session': { access: active, refresh: 'unused' },
    'expired-session': { access: jwt('expired', true), refresh: 'live' },
    'early-session': { access: early, refresh: 'live' },
    'dead-session': { access: jwt('dead', true), refresh: 'dead' },
    'oversize-refresh-session': { access: jwt('large', true), refresh: 'oversize' },
  }));
  fixture = defaultFixture();
  upstream = http.createServer(async (req, res) => {
    calls.push({ method: req.method, path: req.url, headers: req.headers });
    if (req.url === '/auth/refresh') {
      assert.equal(req.headers['x-return-tokens'], 'true');
      if (req.headers['x-refresh-token'] === 'oversize') { send(res, { pad: 'x'.repeat(65537) }); return; }
      if (req.headers['x-refresh-token'] !== 'live') { send(res, {}, 401); return; }
      send(res, { user: { accessToken: renewed, refreshToken: 'rotated' } }); return;
    }
    const auth = req.headers.authorization;
    if (![API_KEY, active, renewed].some(token => auth === `Bearer ${token}`)) { send(res, {}, 401); return; }
    if (req.url === '/api/items/show?expanded=1') {
      if (fixture.delayShow) { await pause(fixture.delayShow); }
      if (fixture.showStatus) { send(res, {}, fixture.showStatus); return; }
      if (fixture.showRaw != null) {
        // No Content-Length: the reader must stop while streaming, before JSON
        // parsing, including when content arrives in multiple chunks.
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.write(fixture.showRaw.slice(0, 100)); res.end(fixture.showRaw.slice(100)); return;
      }
      send(res, fixture.show); return;
    }
    if (req.url.startsWith('/api/me/progress/show/')) {
      if (fixture.delayProgress) { await pause(fixture.delayProgress); }
      const id = req.url.split('/').at(-1);
      if (fixture.progressStatus) { send(res, {}, fixture.progressStatus); return; }
      if (fixture.rows[id]) { send(res, fixture.rows[id]); return; }
      send(res, {}, 404); return;
    }
    send(res, { error: 'unsupported upstream route' }, 500);
  });
  const upstreamPort = await listen(upstream);
  const probe = http.createServer(); const port = await listen(probe);
  await new Promise(resolve => probe.close(resolve));
  base = `http://127.0.0.1:${port}`;
  side = spawn(process.execPath, [SERVER], {
    env: { ...process.env, ABS_URL: `http://127.0.0.1:${upstreamPort}`, PORT: String(port), BIND: '127.0.0.1',
      BASE_PATH: '/proxy', SESSIONS_FILE: join(work, 'sessions.json') }, stdio: ['ignore', 'ignore', 'pipe'],
  });
  side.stderr.on('data', chunk => { sideError += chunk; });
  for (let attempt = 0; attempt < 100; attempt++) {
    try { if ((await fetch(`${base}/health`)).ok) return; } catch {}
    if (side.exitCode !== null) throw new Error(sideError);
    await pause(50);
  }
  throw new Error(`sidecar did not start: ${sideError}`);
});
beforeEach(() => { fixture = defaultFixture(); calls.length = 0; });
after(async () => {
  if (side && side.exitCode === null) { const stopped = new Promise(resolve => side.once('exit', resolve)); side.kill(); await stopped; }
  if (upstream) { await new Promise(resolve => upstream.close(resolve)); }
  if (work) { rmSync(work, { recursive: true, force: true }); }
});
async function get(query = 'show=show&limit=2&order=newest', token = API_KEY) {
  const response = await fetch(`${base}/proxy/podcasts/candidates?${query}&token=${encodeURIComponent(token)}`);
  return { status: response.status, headers: response.headers, body: await response.json() };
}

test('validates parameters before any upstream request', async () => {
  for (const query of ['show=show&limit=0&order=newest', 'show=show&limit=6&order=newest',
    'show=show&limit=01&order=newest', 'show=show&limit=1.5&order=newest', 'show=show&limit=1&order=anything',
    'show=show__episode&limit=1&order=newest', 'show=../show&limit=1&order=newest',
    `show=${'a'.repeat(129)}&limit=1&order=newest`, 'show=show', 'limit=1&order=newest']) {
    assert.equal((await get(query)).status, 400, query);
  }
  assert.equal((await get('show=show&limit=1&order=newest', '')).status, 400);
  assert.equal(calls.length, 0);
});

test('empty success uses bounded versioned data and preserves proxy mount support', async () => {
  const result = await get();
  assert.equal(result.status, 200);
  assert.equal(result.headers.get('cache-control'), 'no-store');
  assert.deepEqual(result.body, { version: 1, checkedAtSec: result.body.checkedAtSec, show: { id: 'show', title: 'My show' }, episodes: [] });
  assert.ok(Math.abs(result.body.checkedAtSec - Date.now() / 1000) < 2);
  assert.deepEqual(calls.map(call => call.path), ['/api/items/show?expanded=1']);
  assert.equal(calls[0].headers.authorization, `Bearer ${API_KEY}`);
});

test('filters finished and unavailable before latest-N, retaining partly played episodes', async () => {
  fixture.show.media.episodes = [episode('old', 1700000000000), episode('partly', 1700000002000),
    episode('new', 1700000003000), episode('finished', 1700000004000),
    episode('no-audio', 1700000005000, { audioFile: null }),
    episode('invalid-audio', 1700000006000, { audioFile: { ino: '1', duration: 0 } }),
    episode('excluded', 1700000007000, { audioFile: { ino: '1', duration: 60, exclude: true } })];
  fixture.rows.partly = progress('partly'); fixture.rows.finished = progress('finished', true);
  const newest = await get();
  assert.equal(newest.status, 200);
  assert.deepEqual(newest.body.episodes, [
    { id: 'show__new', title: 'new', author: 'My show', publishedAt: 1700000003, progress: null },
    { id: 'show__partly', title: 'partly', author: 'My show', publishedAt: 1700000002,
      progress: { currentTime: 12, duration: 60, lastUpdate: 1700000000, isFinished: false } },
  ]);
  assert.deepEqual(calls.map(call => call.path), ['/api/items/show?expanded=1',
    '/api/me/progress/show/finished', '/api/me/progress/show/new', '/api/me/progress/show/partly']);
  const oldest = await get('show=show&limit=2&order=oldest');
  assert.deepEqual(oldest.body.episodes.map(ep => ep.id), ['show__partly', 'show__new']);
});

test('at most five rows, deterministic tie order, and old/new order select the same set', async () => {
  fixture.show.media.episodes = ['f', 'b', 'e', 'd', 'c', 'a'].map(id => episode(id));
  const newest = await get('show=show&limit=5&order=newest');
  const oldest = await get('show=show&limit=5&order=oldest');
  assert.deepEqual(newest.body.episodes.map(ep => ep.id), ['show__a', 'show__b', 'show__c', 'show__d', 'show__e']);
  assert.deepEqual(oldest.body.episodes.map(ep => ep.id), ['show__e', 'show__d', 'show__c', 'show__b', 'show__a']);
});

test('titles are bounded for Unicode and escaped characters, with no upstream metadata leakage', async () => {
  fixture.show.media.metadata = { title: '😀\u0000"\\'.repeat(1000), secret: 'not on watch' };
  fixture.show.media.episodes = ['a', 'b', 'c', 'd', 'e'].map(id => episode(id, 1700000000000, { title: '漢字'.repeat(2000), description: 'not on watch' }));
  const result = await get('show=show&limit=5&order=newest');
  assert.equal(result.status, 200);
  const serialized = JSON.stringify(result.body);
  assert.ok(Buffer.byteLength(serialized) <= 8192);
  assert.ok(Buffer.byteLength(result.body.show.title) <= 160);
  assert.ok(result.body.episodes.every(ep => Buffer.byteLength(ep.title) <= 160));
  assert.ok(!serialized.includes('not on watch'));
});

test('session identity, proactive refresh, and reactive 401 refresh work on discovery', async () => {
  assert.equal((await get(undefined, 'active-session')).status, 200);
  assert.equal(calls[0].headers.authorization, `Bearer ${active}`);
  calls.length = 0;
  assert.equal((await get(undefined, 'expired-session')).status, 200);
  assert.deepEqual(calls.map(call => call.path), ['/auth/refresh', '/api/items/show?expanded=1']);
  assert.equal(calls[1].headers.authorization, `Bearer ${renewed}`);
  assert.equal(JSON.parse(readFileSync(join(work, 'sessions.json'), 'utf8'))['expired-session'].refresh, 'rotated');
  calls.length = 0;
  assert.equal((await get(undefined, 'early-session')).status, 200);
  assert.deepEqual(calls.map(call => call.path), ['/api/items/show?expanded=1', '/auth/refresh', '/api/items/show?expanded=1']);
});

test('bad credentials, expired sessions, and denied item access never expose episodes', async () => {
  for (const token of ['bad-key', 'dead-session', 'key\r\nInjected: yes']) {
    const result = await get(undefined, token);
    assert.equal(result.status, 401);
    assert.ok(!('episodes' in result.body));
  }
  fixture.showStatus = 403;
  assert.equal((await get()).status, 403);
  fixture.showStatus = 404;
  const absent = await get();
  assert.equal(absent.status, 502, 'upstream 404 must not signal an old sidecar');
  assert.equal(absent.body.error, 'ABS 404');
  fixture.showStatus = 503;
  assert.equal((await get()).status, 502);
});

test('non-podcast and malformed show/episode payloads fail without progress requests', async () => {
  for (const show of [{ id: 'show', mediaType: 'book', media: {} }, null,
    { id: 'wrong', mediaType: 'podcast', media: { episodes: [] } },
    { id: 'show', mediaType: 'podcast', media: { episodes: {} } }]) {
    fixture.show = show;
    const result = await get();
    assert.equal(result.status, show?.mediaType === 'book' ? 400 : 502);
  }
  for (const episodes of [[null], [episode('a'), episode('a')], [episode('../bad')], [episode('a', 'yesterday')]]) {
    fixture.show = defaultFixture().show; fixture.show.media.episodes = episodes;
    assert.equal((await get()).status, 502);
  }
  assert.ok(calls.every(call => call.path === '/api/items/show?expanded=1'));
});

test('progress failures, wrong identity and malformed rows never return partial success', async () => {
  fixture.show.media.episodes = [episode('a'), episode('b')];
  for (const row of [progress('b', false, { episodeId: 'different' }), progress('b', false, { libraryItemId: 'different' }),
    progress('b', false, { isFinished: 'true' }), progress('b', false, { duration: '60' }), {}]) {
    fixture.rows.b = row;
    const result = await get();
    assert.equal(result.status, 502);
    assert.ok(!('episodes' in result.body));
  }
  fixture.rows = {}; fixture.progressStatus = 503;
  assert.equal((await get()).status, 502);
});

test('oversized numeric metadata fails before emitting any candidates to the watch', async () => {
  for (const publishedAt of [Number.MAX_VALUE, 2147483648000]) {
    fixture.show.media.episodes = [episode('a'), episode('b', publishedAt)];
    const result = await get();
    assert.equal(result.status, 502);
    assert.ok(!('episodes' in result.body));
    assert.match(result.body.error, /malformed podcast episode/);
  }
  fixture.show.media.episodes = [episode('a'), episode('b')];
  for (const [key, value] of [['currentTime', Number.MAX_VALUE], ['duration', Number.MAX_VALUE],
    ['lastUpdate', Number.MAX_VALUE], ['currentTime', 1000000001], ['duration', 1000000001], ['lastUpdate', 2147483648000]]) {
    fixture.rows.b = progress('b', false, { [key]: value });
    const result = await get();
    assert.equal(result.status, 502, `${key}=${value}`);
    assert.ok(!('episodes' in result.body), 'even an earlier valid candidate must not leak');
    assert.match(result.body.error, /malformed podcast progress/);
  }
  fixture.rows = {};
  for (const duration of [Number.MAX_VALUE, 1000000001]) {
    fixture.show.media.episodes = [episode('a', 1700000000000, { audioFile: { ino: '1', duration } })];
    const result = await get();
    assert.equal(result.status, 502);
    assert.ok(!('episodes' in result.body));
  }
});

test('valid numeric boundaries convert ABS millisecond timestamps to watch seconds', async () => {
  fixture.show.media.episodes = [episode('a', 2147483647999)];
  fixture.rows.a = progress('a', false, { currentTime: 1000000000, duration: 1000000000, lastUpdate: 2147483647999 });
  const result = await get();
  assert.equal(result.status, 200);
  assert.equal(result.body.episodes[0].publishedAt, 2147483647);
  assert.deepEqual(result.body.episodes[0].progress, {
    currentTime: 1000000000, duration: 1000000000, lastUpdate: 2147483647, isFinished: false,
  });
});

test('show, progress and refresh streaming payloads have hard byte limits', async () => {
  fixture.showRaw = JSON.stringify({ pad: 'x'.repeat(1048576) });
  let result = await get();
  assert.equal(result.status, 502); assert.match(result.body.error, /too large/);
  fixture.showRaw = '{bad json';
  result = await get(); assert.equal(result.status, 502); assert.match(result.body.error, /malformed/);
  fixture.showRaw = null;
  fixture.show.media.episodes = [episode('a')];
  fixture.rows.a = progress('a', false, { pad: 'x'.repeat(4096) });
  result = await get(); assert.equal(result.status, 502); assert.match(result.body.error, /too large/);
  result = await get(undefined, 'oversize-refresh-session');
  assert.equal(result.status, 502); assert.match(result.body.error, /too large/);
});

test('episode-count and total-request ceilings fail closed, not as an empty or partial set', async () => {
  fixture.show.media.episodes = Array.from({ length: 2001 }, (_, i) => episode(`ep-${i}`));
  let result = await get();
  assert.equal(result.status, 502); assert.match(result.body.error, /show too large/);
  assert.equal(calls.length, 1);
  calls.length = 0;
  fixture.show.media.episodes = Array.from({ length: 40 }, (_, i) => episode(`ep-${String(i).padStart(2, '0')}`));
  for (const ep of fixture.show.media.episodes) { fixture.rows[ep.id] = progress(ep.id, true); }
  result = await get();
  assert.equal(result.status, 502); assert.match(result.body.error, /limit reached/);
  assert.equal(calls.length, 32);
  assert.ok(!('episodes' in result.body));
});

test('one deadline covers consecutive upstream calls, not a fresh timeout per episode', { timeout: 16000 }, async () => {
  fixture.show.media.episodes = [episode('a')];
  fixture.delayShow = 6500; fixture.delayProgress = 6500;
  const started = Date.now();
  const result = await get();
  const elapsed = Date.now() - started;
  assert.equal(result.status, 502); assert.match(result.body.error, /timed out/);
  assert.ok(elapsed >= 11000 && elapsed < 13500, `elapsed ${elapsed}`);
  assert.equal(calls.length, 2);
});
