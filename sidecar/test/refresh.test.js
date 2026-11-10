// A token refresh has three outcomes and the watch must be able to tell them
// apart: renewed, rejected by ABS (401 -> the watch sends the user to log in),
// or unknown because ABS could not answer (5xx -> the watch retries). Drives the
// real sidecar against a fake ABS whose /auth/refresh behaviour is picked by the
// stored refresh token.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { sidecarTmpdir } from './sidecar-tmpdir.js';

const SERVER = fileURLToPath(new URL('../server.js', import.meta.url));
const now = Math.floor(Date.now() / 1000);
const jwt = (expires, name) => `h.${Buffer.from(JSON.stringify({ exp: expires, sub: name })).toString('base64url')}.s`;
const nearExpiry = jwt(now + 30, 'near-expiry');   // still valid, inside the 60s proactive window
const revokedEarly = jwt(now + 3600, 'revoked-early');   // looks valid, but ABS refuses it
const renewed = jwt(now + 3600, 'renewed');
const expired = name => jwt(now - 60, name);
const hasFfmpeg = spawnSync('ffmpeg', ['-version']).status === 0;
const calls = [];
let abs, side, base, work, sideTmp, sessionsFile, audio, sideError = '', flakyDown = true;
const listen = server => new Promise(resolve => server.listen(0, '127.0.0.1', () => resolve(server.address().port)));

const sessions = {
  'expired-down': { access: expired('a'), refresh: 'down' },
  'expired-500': { access: expired('b'), refresh: 'status-500' },
  'expired-429': { access: expired('h'), refresh: 'status-429' },
  'expired-403': { access: expired('i'), refresh: 'status-403' },
  'expired-html': { access: expired('c'), refresh: 'html' },
  'expired-no-token': { access: expired('d'), refresh: 'no-token' },
  'expired-rejected': { access: expired('e'), refresh: 'rejected' },
  'expired-no-refresh': { access: expired('f'), refresh: null },
  'expired-flaky': { access: expired('g'), refresh: 'flaky' },
  'near-down': { access: nearExpiry, refresh: 'down' },
  'near-500': { access: nearExpiry, refresh: 'status-500' },
  'near-rejected': { access: nearExpiry, refresh: 'rejected' },
  'revoked-down': { access: revokedEarly, refresh: 'down' },
  'revoked-rejected': { access: revokedEarly, refresh: 'rejected' },
};

before(async () => {
  work = mkdtempSync(join(tmpdir(), 'watchshelf-refresh-test-'));
  sessionsFile = join(work, 'sessions.json');
  writeFileSync(sessionsFile, JSON.stringify(sessions));
  if (hasFfmpeg) {
    const input = join(work, 'input.wav');
    const generated = spawnSync('ffmpeg', ['-hide_banner', '-loglevel', 'error',
      '-f', 'lavfi', '-i', 'sine=frequency=440:duration=1', input]);
    assert.equal(generated.status, 0, generated.stderr.toString());
    audio = readFileSync(input);
  }
  abs = http.createServer((req, res) => {
    calls.push({ method: req.method, path: req.url, headers: req.headers });
    const send = (body, status = 200) => res.writeHead(status, { 'Content-Type': 'application/json' }).end(JSON.stringify(body));
    if (req.url === '/auth/refresh') {
      const mode = req.headers['x-refresh-token'];
      // Dropping the socket makes the sidecar's fetch() fail exactly as it does
      // when ABS is down or a network hop blips.
      if (mode === 'down' || (mode === 'flaky' && flakyDown)) { req.socket.destroy(); return; }
      if (mode.startsWith('status-')) { send({ error: 'boom' }, Number(mode.slice(7))); return; }
      if (mode === 'html') { res.writeHead(200, { 'Content-Type': 'text/html' }).end('<html>proxy page</html>'); return; }
      if (mode === 'no-token') { send({ user: {} }); return; }
      if (mode === 'flaky') { send({ user: { accessToken: renewed, refreshToken: 'flaky-rotated' } }); return; }
      send({ error: 'Invalid refresh token' }, 401); return;
    }
    if (![nearExpiry, renewed].some(token => req.headers.authorization === `Bearer ${token}`)) {
      send({ error: 'Unauthorized' }, 401); return;
    }
    if (req.url === '/api/libraries') { send({ libraries: [{ id: 'books', name: 'Books' }] }); return; }
    if (req.url === '/api/me/progress/book' && req.method === 'PATCH') { send({ ok: true }); return; }
    if (req.url === '/api/items/book/file/1/download' && audio) {
      res.writeHead(200, { 'Content-Type': 'audio/wav', 'Content-Length': audio.length }).end(audio); return;
    }
    send({ error: 'missing' }, 404);
  });
  const absPort = await listen(abs);
  const probe = http.createServer();
  const sidePort = await listen(probe);
  await new Promise(resolve => probe.close(resolve));
  base = `http://127.0.0.1:${sidePort}`;
  sideTmp = sidecarTmpdir();
  side = spawn(process.execPath, [SERVER], {
    env: { ...process.env, ABS_URL: `http://127.0.0.1:${absPort}`, PORT: String(sidePort),
      BIND: '127.0.0.1', BASE_PATH: '', SESSIONS_FILE: sessionsFile, TMPDIR: sideTmp },
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  side.stderr.on('data', chunk => { sideError += chunk; });
  for (let attempt = 0; attempt < 100; attempt++) {
    try { if ((await fetch(`${base}/health`)).ok) return; } catch {}
    if (side.exitCode !== null) throw new Error(sideError);
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  throw new Error(`sidecar did not become ready: ${sideError}`);
});

after(async () => {
  if (side && side.exitCode === null) {
    const stopped = new Promise(resolve => side.once('exit', resolve));
    side.kill();
    await stopped;
  }
  if (abs) await new Promise(resolve => abs.close(resolve));
  if (work) rmSync(work, { recursive: true, force: true });
  if (sideTmp) rmSync(sideTmp, { recursive: true, force: true });
});

const request = (path, token, options) => fetch(`${base}${path}${path.includes('?') ? '&' : '?'}token=${encodeURIComponent(token)}`, options);
const postProgress = token => request('/progress', token, {
  method: 'POST', headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ itemId: 'book', currentTime: 12, duration: 60 }),
});
// Every route that needs an access token, including the three that resolve it
// directly rather than through absJson.
const everyRoute = {
  transcode: token => request('/transcode?item=book&file=1&fmt=m4a3&start=0&end=1', token),
  cover: token => request('/cover?item=book', token),
  'progress write': postProgress,
  'progress read': token => request('/progress?item=book', token),
  libraries: token => request('/libraries', token),
  list: token => request('/list?lib=books', token),
  files: token => request('/files?item=book', token),
};
const candidates = token => request('/podcasts/candidates?show=show&limit=2&order=newest', token);

test('ABS unreachable during refresh is a retryable 5xx on every route, not an expired session', async () => {
  for (const [name, call] of Object.entries(everyRoute)) {
    calls.length = 0;
    const response = await call('expired-down');
    assert.ok(response.status >= 500 && response.status <= 599, `${name} answered ${response.status}`);
    assert.deepEqual(calls.map(c => c.path), ['/auth/refresh'], `${name} must not use the expired token`);
  }
  assert.equal((await fetch(`${base}/health`)).status, 200, 'a failed refresh must not take the sidecar down');
});

test('routes that resolve the token directly answer 503', async () => {
  assert.equal((await everyRoute.transcode('expired-down')).status, 503);
  assert.equal((await everyRoute.cover('expired-down')).status, 503);
  const progress = await postProgress('expired-down');
  assert.equal(progress.status, 503);
  assert.deepEqual(await progress.json(), { error: 'ABS unreachable' }, 'JSON routes must keep JSON error bodies');
});

test('only a 401 from ABS is a rejection, not a 5xx, rate limit, proxy status or bad body', async () => {
  for (const sid of ['expired-500', 'expired-429', 'expired-403', 'expired-html', 'expired-no-token']) {
    for (const [name, call] of Object.entries(everyRoute)) {
      const response = await call(sid);
      assert.ok(response.status >= 500 && response.status <= 599, `${sid} ${name} answered ${response.status}`);
    }
  }
});

test('ABS rejecting the refresh token is still 401 on every route', async () => {
  for (const sid of ['expired-rejected', 'near-rejected', 'expired-no-refresh']) {
    for (const [name, call] of Object.entries(everyRoute)) {
      assert.equal((await call(sid)).status, 401, `${sid} ${name}`);
    }
  }
});

test('an unexpired token keeps working when the proactive refresh fails', async () => {
  for (const sid of ['near-down', 'near-500']) {
    calls.length = 0;
    const libraries = await request('/libraries', sid);
    assert.equal(libraries.status, 200, sid);
    assert.equal((await libraries.json()).libraries[0].id, 'books');
    assert.deepEqual(calls.map(c => c.path), ['/auth/refresh', '/api/libraries']);
    assert.equal(calls[1].headers.authorization, `Bearer ${nearExpiry}`);
    assert.equal((await postProgress(sid)).status, 200, sid);
  }
});

test('an unexpired token keeps transcoding when the proactive refresh fails', { skip: !hasFfmpeg }, async () => {
  calls.length = 0;
  const response = await everyRoute.transcode('near-down');
  assert.equal(response.status, 200, sideError);
  assert.ok((await response.arrayBuffer()).byteLength > 0);
  assert.equal(calls[0].path, '/auth/refresh');
  assert.equal(calls[1].headers.authorization, `Bearer ${nearExpiry}`);
});

test('a token ABS refuses early follows the refresh outcome', async () => {
  // Reactive path: the access token looked valid, ABS 401ed it, then refreshed.
  calls.length = 0;
  const unknown = await request('/libraries', 'revoked-down');
  assert.ok(unknown.status >= 500 && unknown.status <= 599, `answered ${unknown.status}`);
  assert.deepEqual(calls.map(c => c.path), ['/api/libraries', '/auth/refresh']);
  assert.equal((await request('/libraries', 'revoked-rejected')).status, 401);
});

test('a session survives a failed refresh and renews once ABS is back', async () => {
  flakyDown = true;
  const down = await request('/libraries', 'expired-flaky');
  assert.ok(down.status >= 500 && down.status <= 599, `answered ${down.status}`);
  assert.equal(JSON.parse(readFileSync(sessionsFile, 'utf8'))['expired-flaky'].refresh, 'flaky',
    'a failed refresh must not discard the stored refresh token');
  flakyDown = false;
  calls.length = 0;
  assert.equal((await request('/libraries', 'expired-flaky')).status, 200);
  assert.equal(calls[1].headers.authorization, `Bearer ${renewed}`);
  assert.equal(JSON.parse(readFileSync(sessionsFile, 'utf8'))['expired-flaky'].refresh, 'flaky-rotated');
});

test('podcast discovery fails closed on a refresh failure, with no fallback to the current token', async () => {
  for (const sid of ['expired-down', 'expired-500', 'expired-html', 'expired-no-token', 'near-down', 'near-500']) {
    calls.length = 0;
    const response = await candidates(sid);
    assert.equal(response.status, 502, sid);
    assert.ok(!('episodes' in await response.json()), sid);
    assert.deepEqual(calls.map(c => c.path), ['/auth/refresh'], `${sid} must stop at the failed refresh`);
  }
  assert.equal((await candidates('expired-rejected')).status, 401);
  assert.equal((await candidates('near-rejected')).status, 401);
});
