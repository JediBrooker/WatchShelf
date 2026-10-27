import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const SERVER = fileURLToPath(new URL('../server.js', import.meta.url));
const API_KEY = 'api-key._~+/-==';
const jwt = (expires, user) => `h.${Buffer.from(JSON.stringify({ exp: expires, sub: user })).toString('base64url')}.s`;
const now = Math.floor(Date.now() / 1000);
const activeAccess = jwt(now + 3600, 'active');
const renewedAccess = jwt(now + 3600, 'renewed');
const calls = [];
const hasFfmpeg = spawnSync('ffmpeg', ['-version']).status === 0;
let abs, side, base, work, sessionsFile, audio, revoked = false, sideError = '';
const listen = server => new Promise(resolve => server.listen(0, '127.0.0.1', () => resolve(server.address().port)));

before(async () => {
  work = mkdtempSync(join(tmpdir(), 'watchshelf-auth-test-'));
  sessionsFile = join(work, 'sessions.json');
  writeFileSync(sessionsFile, JSON.stringify({
    'active-session': { access: activeAccess, refresh: 'unused' },
    'expired-session': { access: jwt(now - 60, 'expired'), refresh: 'dead' },
    'refreshing-session': { access: jwt(now - 60, 'refreshing'), refresh: 'live' },
  }));
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
      if (req.headers['x-refresh-token'] !== 'live') { send({ error: 'expired' }, 401); return; }
      send({ user: { accessToken: renewedAccess, refreshToken: 'rotated' } }); return;
    }
    const accepted = [activeAccess, renewedAccess, ...(revoked ? [] : [API_KEY])];
    if (!accepted.some(token => req.headers.authorization === `Bearer ${token}`)) {
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
  side = spawn(process.execPath, [SERVER], {
    env: { ...process.env, ABS_URL: `http://127.0.0.1:${absPort}`, PORT: String(sidePort),
      BIND: '127.0.0.1', BASE_PATH: '', SESSIONS_FILE: sessionsFile },
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
});

const request = (path, token, options) => fetch(`${base}${path}${path.includes('?') ? '&' : '?'}token=${encodeURIComponent(token)}`, options);

test('API keys keep their exact bearer value for reads and progress writes', async () => {
  calls.length = 0;
  const libraries = await request('/libraries', API_KEY);
  assert.equal(libraries.status, 200);
  assert.equal((await libraries.json()).libraries[0].id, 'books');
  const progress = await request('/progress', API_KEY, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ itemId: 'book', currentTime: 12, duration: 60 }),
  });
  assert.equal(progress.status, 200);
  assert.deepEqual(calls.map(call => [call.method, call.path, call.headers.authorization]), [
    ['GET', '/api/libraries', `Bearer ${API_KEY}`],
    ['PATCH', '/api/me/progress/book', `Bearer ${API_KEY}`],
  ]);
});

test('unknown stale sessions are rejected by ABS, without a refresh attempt', async () => {
  calls.length = 0;
  const stale = 'bb79a396-f539-4612-9510-1376de5ae36c';
  const response = await request('/libraries', stale);
  assert.equal(response.status, 401);
  assert.deepEqual(await response.json(), { error: 'ABS 401' });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].headers.authorization, `Bearer ${stale}`);
});

test('stored sessions retain their user identity and rotate their refresh token', async () => {
  calls.length = 0;
  assert.equal((await request('/libraries', 'active-session')).status, 200);
  assert.equal(calls[0].headers.authorization, `Bearer ${activeAccess}`);
  assert.equal((await request('/libraries', 'refreshing-session')).status, 200);
  assert.deepEqual(calls.map(call => call.path), ['/api/libraries', '/auth/refresh', '/api/libraries']);
  assert.equal(calls[1].headers['x-refresh-token'], 'live');
  assert.equal(calls[2].headers.authorization, `Bearer ${renewedAccess}`);
  assert.equal(JSON.parse(readFileSync(sessionsFile, 'utf8'))['refreshing-session'].refresh, 'rotated');
});

test('expired stored sessions never fall back to treating their session id as an API key', async () => {
  calls.length = 0;
  const response = await request('/libraries', 'expired-session');
  assert.equal(response.status, 401);
  assert.deepEqual(await response.json(), { error: 'unauthorized' });
  assert.deepEqual(calls.map(call => call.path), ['/auth/refresh']);
});

test('audio requests authenticate every time, including after API-key revocation', { skip: !hasFfmpeg }, async () => {
  try {
    for (const fmt of ['mp3', 'm4a3']) {
      calls.length = 0;
      const path = `/transcode?item=book&file=1&fmt=${fmt}&start=0&end=1`;
      revoked = false;
      const valid = await request(path, API_KEY);
      assert.equal(valid.status, 200, sideError);
      assert.equal(valid.headers.get('cache-control'), 'no-store');
      assert.ok((await valid.arrayBuffer()).byteLength > 0);
      assert.equal(calls[0].headers.authorization, `Bearer ${API_KEY}`);
      const authorizedCalls = calls.length;
      revoked = true;
      const rejected = await request(path, API_KEY);
      assert.equal(rejected.status, 401);
      assert.ok(calls.length > authorizedCalls, 'a repeated URL must still reach ABS for authorization');
    }
  } finally { revoked = false; }
});

test('malformed credentials cannot inject ffmpeg headers or crash the sidecar', async () => {
  calls.length = 0;
  for (const token of ['key\0', 'key\r\nX-Injected: yes', 'key\n', 'key\t', 'key\x7f', 'key\u0100', 'key with spaces']) {
    for (const path of ['/transcode?item=book&file=1&fmt=mp3', '/transcode?item=book&file=1&fmt=m4a3', '/libraries']) {
      const response = await request(path, token);
      assert.equal(response.status, 401, `${path} must reject ${JSON.stringify(token)}`);
    }
  }
  assert.equal(calls.length, 0, 'malformed credentials must never reach ABS');
  assert.equal((await fetch(`${base}/health`)).status, 200, 'the sidecar must remain alive');
});
