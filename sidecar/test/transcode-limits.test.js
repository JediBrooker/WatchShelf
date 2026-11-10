// The bounds on an m4a chunk: wall-clock limit, network timeout, temp-file
// cleanup, the ffmpeg queue, and the per-request log. These run the real sidecar
// and real ffmpeg against a mock ABS that can stall on demand, so they pin down
// how ffmpeg actually behaves with these flags. None of this goes through
// Cloudflare or any other proxy.
import { test, before, after, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { spawn, spawnSync } from 'node:child_process';
import { chmodSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const SERVER = fileURLToPath(new URL('../server.js', import.meta.url));
const hasFfmpeg = spawnSync('ffmpeg', ['-version']).status === 0
  && spawnSync('ffprobe', ['-version']).status === 0;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const listen = (server) => new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server.address().port)));

async function until(check, what, timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (check()) { return; }
    await sleep(25);
  }
  assert.fail(`timed out waiting for ${what}`);
}

let work, audio;
const cleanups = [];

before(() => {
  work = mkdtempSync(join(tmpdir(), 'watchshelf-limits-test-'));
  if (!hasFfmpeg) { return; }
  const input = join(work, 'input.wav');
  const generated = spawnSync('ffmpeg', ['-hide_banner', '-loglevel', 'error',
    '-f', 'lavfi', '-i', 'sine=frequency=440:duration=60', '-ar', '44100', input]);
  assert.equal(generated.status, 0, generated.stderr.toString());
  audio = readFileSync(input);
});
afterEach(async () => {
  while (cleanups.length) { await cleanups.pop()(); }
});
after(() => rmSync(work, { recursive: true, force: true }));

// A mock ABS whose behaviour is chosen by the item id's prefix:
//   ok-      serves the file, honouring Range like the real thing
//   hold-    says nothing until release() is called, then serves the file normally
//   silent-  accepts the request and never answers
//   stall-   sends part of the file on every connection, then goes quiet
//   die-     sends part of the file twice (ffmpeg's probe and seek), then never
//            answers again, as when ABS wedges partway through a chunk
//   blip-    like die- for one more connection, then recovers and serves the rest
//   denied-  answers 401
async function startAbs(accessToken) {
  const seen = [];
  const files = [];
  const counts = {};
  const open = new Set();
  let held = [];
  const released = new Set();
  const serve = (req, res) => {
    const from = Number(/bytes=(\d+)-/.exec(req.headers.range || '')?.[1] || 0);
    res.writeHead(from ? 206 : 200, { 'Content-Type': 'audio/wav', 'Accept-Ranges': 'bytes',
      'Content-Length': audio.length - from,
      ...(from ? { 'Content-Range': `bytes ${from}-${audio.length - 1}/${audio.length}` } : {}) });
    return from;
  };
  const server = http.createServer((req, res) => {
    if (req.method === 'POST' && req.url === '/login') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ user: { accessToken, username: 'test' } }));
      return;
    }
    const [, item, file] = /^\/api\/items\/([^/]+)\/file\/(-?[0-9]+)\/download$/.exec(req.url) || [];
    if (!item) { res.writeHead(404).end(); return; }
    files.push(file);
    if (!seen.includes(item)) { seen.push(item); }
    counts[item] = (counts[item] || 0) + 1;
    open.add(req.socket);
    req.socket.once('close', () => open.delete(req.socket));
    const partial = () => { const from = serve(req, res); res.write(audio.subarray(from, from + 2000000)); };
    const full = () => { const from = serve(req, res); res.end(audio.subarray(from)); };
    if (item.startsWith('ok-')) { full(); }
    else if (item.startsWith('hold-')) { if (released.has(item)) { full(); } else { held.push({ item, full }); } }
    else if (item.startsWith('stall-')) { partial(); }
    else if (item.startsWith('die-')) { if (counts[item] <= 2) { partial(); } }
    else if (item.startsWith('blip-')) { if (counts[item] <= 2) { partial(); } else if (counts[item] > 3) { full(); } }
    else if (item.startsWith('denied-')) { res.writeHead(401).end(); }
    // silent-: no answer at all
  });
  const port = await listen(server);
  cleanups.push(() => {
    server.closeAllConnections();
    return new Promise((resolve) => server.close(resolve));
  });
  return {
    port, seen, files, open,
    release() {
      const waiting = held;
      held = [];
      waiting.forEach(({ item, full }) => { released.add(item); full(); });
    },
  };
}

async function startSidecar(absPort, env = {}) {
  const tmp = mkdtempSync(join(work, 'tmp-'));
  const probe = http.createServer();
  const port = await listen(probe);
  await new Promise((resolve) => probe.close(resolve));
  const side = spawn(process.execPath, [SERVER], {
    env: { ...process.env, ABS_URL: `http://127.0.0.1:${absPort}`, PORT: String(port), BIND: '127.0.0.1',
      BASE_PATH: '', TMPDIR: tmp, SESSIONS_FILE: '', ...env },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const output = { text: '' };
  side.stdout.on('data', (chunk) => { output.text += chunk; });
  side.stderr.on('data', (chunk) => { output.text += chunk; });
  cleanups.push(() => new Promise((resolve) => {
    side.once('close', resolve);
    side.kill('SIGKILL');
  }));
  const base = `http://127.0.0.1:${port}`;
  await until(() => output.text.includes('WatchShelf sidecar'), 'sidecar startup');
  const url = (item, extra = 'start=0&end=30', token = 'test-api-key') =>
    `${base}/transcode?item=${item}&file=1&fmt=m4a3&${extra}&token=${token}`;
  const tempFiles = () => readdirSync(tmp).filter((name) => name.startsWith('watchshelf-'));
  const lines = () => output.text.split('\n').filter((line) => line.startsWith('transcode '));
  const lineFor = (item) => lines().find((line) => line.includes(` item=${item} `));
  return { base, url, output, tempFiles, lines, lineFor };
}

const ffmpegGone = (abs) => until(() => abs.open.size === 0, 'ffmpeg to drop its connections to ABS');

test('wall-clock limit kills ffmpeg, answers 504, removes the temp file and frees the slot', { skip: !hasFfmpeg }, async () => {
  const abs = await startAbs('unused');
  const side = await startSidecar(abs.port, { TRANSCODE_TIMEOUT_MS: '3000', FFMPEG_RW_TIMEOUT_MS: '60000', TRANSCODE_CONCURRENCY: '1' });
  const startedAt = Date.now();
  const pending = fetch(side.url('stall-a'));
  await until(() => side.tempFiles().length === 1, 'ffmpeg to start writing its temp file');
  const response = await pending;
  const elapsed = Date.now() - startedAt;
  assert.equal(response.status, 504);
  assert.ok(elapsed >= 2500 && elapsed < 6000, `answered after ${elapsed}ms`);
  await ffmpegGone(abs);
  await until(() => side.tempFiles().length === 0, 'the temp file to be removed');
  // The slot came back: with a cap of 1 this would otherwise wait and then 503.
  const next = await fetch(side.url('ok-b', 'start=0&end=4'));
  assert.equal(next.status, 200);
  await until(() => side.lineFor('stall-a'), 'the log line');
  assert.match(side.lineFor('stall-a'), /^transcode status=504 ms=\d+ queuedMs=\d+ item=stall-a file=1 range=0-30 clientGone=false$/);
});

test('the network timeout fails a source that never answers, without the wall-clock limit', { skip: !hasFfmpeg }, async () => {
  const abs = await startAbs('unused');
  const side = await startSidecar(abs.port, { TRANSCODE_TIMEOUT_MS: '60000', FFMPEG_RW_TIMEOUT_MS: '500' });
  const startedAt = Date.now();
  const response = await fetch(side.url('silent-a'));
  assert.equal(response.status, 502);
  assert.ok(Date.now() - startedAt < 10000, 'should fail on the network timeout, not the 60s limit');
  await until(() => side.tempFiles().length === 0, 'the temp file to be removed');
});

test('a source that dies mid-chunk gets a 502 rather than a truncated 200', { skip: !hasFfmpeg }, async () => {
  const abs = await startAbs('unused');
  const side = await startSidecar(abs.port, { TRANSCODE_TIMEOUT_MS: '60000', FFMPEG_RW_TIMEOUT_MS: '500' });
  const response = await fetch(side.url('die-a', 'start=0&end=50'));
  // ffmpeg itself exits 0 here with about 18s of the 50s asked for.
  assert.equal(response.status, 502);
  await until(() => side.tempFiles().length === 0, 'the temp file to be removed');
});

test('a brief stall resumes through reconnect and still delivers the whole chunk', { skip: !hasFfmpeg }, async () => {
  const abs = await startAbs('unused');
  const side = await startSidecar(abs.port, { TRANSCODE_TIMEOUT_MS: '60000', FFMPEG_RW_TIMEOUT_MS: '500' });
  const response = await fetch(side.url('blip-a', 'start=0&end=50'));
  assert.equal(response.status, 200);
  const output = join(work, 'blip.m4a');
  writeFileSync(output, Buffer.from(await response.arrayBuffer()));
  const probe = spawnSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'default=nw=1:nk=1', output]);
  const duration = Number(probe.stdout.toString().trim());
  assert.ok(Math.abs(duration - 50) < 0.5, `expected about 50s, received ${duration}s`);
});

test('a client that leaves mid-transcode kills ffmpeg and removes the temp file', { skip: !hasFfmpeg }, async () => {
  const abs = await startAbs('unused');
  const side = await startSidecar(abs.port, { TRANSCODE_TIMEOUT_MS: '60000', FFMPEG_RW_TIMEOUT_MS: '60000' });
  const client = new AbortController();
  const pending = fetch(side.url('stall-a'), { signal: client.signal }).catch(() => null);
  await until(() => side.tempFiles().length === 1, 'ffmpeg to start writing its temp file');
  client.abort();
  await pending;
  await ffmpegGone(abs);
  await until(() => side.tempFiles().length === 0, 'the temp file to be removed');
  await until(() => side.lineFor('stall-a'), 'the log line');
  assert.match(side.lineFor('stall-a'), /^transcode status=- ms=\d+ queuedMs=\d+ item=stall-a file=1 range=0-30 clientGone=true$/);
});

test('concurrent ffmpeg processes stay under the cap and queued requests still complete', { skip: !hasFfmpeg }, async () => {
  const abs = await startAbs('unused');
  const side = await startSidecar(abs.port, { TRANSCODE_CONCURRENCY: '2' });
  const pending = ['hold-a', 'hold-b', 'hold-c'].map(async (item) => {
    const response = await fetch(side.url(item, 'start=0&end=4'));
    await response.arrayBuffer();
    return response.status;
  });
  await until(() => abs.seen.length === 2, 'two transcodes to reach ABS');
  await sleep(400);
  assert.equal(abs.seen.length, 2, 'the third request must wait for a slot');
  while (abs.seen.length < 3) {
    abs.release();
    await sleep(25);
  }
  abs.release();
  assert.deepEqual(await Promise.all(pending), [200, 200, 200]);
  await until(() => side.lines().length === 3, 'three log lines');
  const queued = side.lines().map((line) => Number(/queuedMs=(\d+)/.exec(line)[1]));
  assert.ok(Math.max(...queued) >= 300, `one request should show its queue wait: ${queued}`);
});

test('a queued request whose client disconnects drops out and never starts ffmpeg', { skip: !hasFfmpeg }, async () => {
  const abs = await startAbs('unused');
  const side = await startSidecar(abs.port, { TRANSCODE_CONCURRENCY: '1' });
  const first = fetch(side.url('hold-a', 'start=0&end=4'));
  await until(() => abs.seen.includes('hold-a'), 'the first transcode to take the slot');
  const client = new AbortController();
  const abandoned = fetch(side.url('ok-gone', 'start=0&end=4'), { signal: client.signal }).catch(() => null);
  const third = fetch(side.url('ok-next', 'start=0&end=4'));
  await sleep(200);
  client.abort();
  await abandoned;
  await until(() => side.lineFor('ok-gone'), 'the abandoned request to be logged');
  assert.match(side.lineFor('ok-gone'), /^transcode status=- .* clientGone=true$/);
  abs.release();
  assert.equal((await first).status, 200);
  assert.equal((await third).status, 200);
  assert.deepEqual(abs.seen, ['hold-a', 'ok-next']);
  assert.deepEqual(side.tempFiles(), []);
});

// The wall-clock limit covers queue wait, or a long queue would outlast the proxy.
// A real ffmpeg dies too fast to keep the slot past its own deadline, so this
// stand-in leaves a child holding stderr: 'close' stays pending after SIGKILL, as
// with a process stuck in uninterruptible I/O.
test('a request that never gets a slot answers 503 by the deadline, even if the running child is slow to die', async () => {
  const bin = mkdtempSync(join(work, 'bin-'));
  const runs = join(bin, 'runs');
  const fake = join(bin, 'ffmpeg');
  writeFileSync(fake, `#!/bin/sh\necho run >> "${runs}"\nsleep 3 &\nwait\n`);
  chmodSync(fake, 0o755);
  const side = await startSidecar(1, { TRANSCODE_TIMEOUT_MS: '800', TRANSCODE_CONCURRENCY: '1',
    PATH: `${bin}:${process.env.PATH}` });
  const startedAt = Date.now();
  const running = fetch(side.url('slow-a'));
  await until(() => { try { return readFileSync(runs, 'utf8').length > 0; } catch { return false; } }, 'the stand-in to start');
  const queued = await fetch(side.url('slow-b'));
  assert.equal((await running).status, 504);
  assert.equal(queued.status, 503);
  assert.ok(Date.now() - startedAt < 2500, 'both must answer without waiting for the child to exit');
  // Once the child really has gone its slot is free, and the expired request must
  // not be left in the queue to take it.
  await sleep(startedAt + 3500 - Date.now());
  assert.equal(readFileSync(runs, 'utf8'), 'run\n', 'the expired request must never start');
  await until(() => side.lineFor('slow-b'), 'the log line');
  assert.match(side.lineFor('slow-b'), /^transcode status=503 .* item=slow-b .* clientGone=false$/);
});

test('every request logs one line and no token reaches the logs', { skip: !hasFfmpeg }, async () => {
  const access = `h.${Buffer.from(JSON.stringify({ exp: Math.floor(Date.now() / 1000) + 3600 })).toString('base64url')}.ACCESS-TOKEN-SECRET`;
  const abs = await startAbs(access);
  const side = await startSidecar(abs.port, { FFMPEG_RW_TIMEOUT_MS: '500' });
  const timingOut = await startSidecar(abs.port, { TRANSCODE_TIMEOUT_MS: '1000', FFMPEG_RW_TIMEOUT_MS: '60000' });
  const login = await fetch(`${side.base}/login`, { method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: 'test', password: 'test' }) });
  const session = (await login.json()).user.token;
  const apiKey = 'API-KEY-SECRET';

  const statusOf = async (url) => {
    const response = await fetch(url);
    await response.arrayBuffer();
    return response.status;
  };
  // Success, ffmpeg's stderr on an upstream rejection and on a network timeout, the
  // wall-clock limit, and each early exit, with both kinds of credential. A token
  // in item or in a query value that fails validation must not get through either.
  assert.equal(await statusOf(side.url('ok-a', 'start=0&end=4', session)), 200);
  assert.equal(await statusOf(side.url('denied-a', 'start=0&end=4', session)), 401);
  assert.equal(await statusOf(side.url('silent-a', 'start=0&end=4', session)), 502);
  assert.equal(await statusOf(side.url('silent-b', 'start=0&end=4', apiKey)), 502);
  assert.equal(await statusOf(timingOut.url('stall-a', 'start=0&end=50', apiKey)), 504);
  assert.equal(await statusOf(`${side.base}/transcode?item=ok-b&file=1&fmt=nope&token=${session}`), 400);
  assert.equal(await statusOf(`${side.base}/transcode?item=ok-b&file=1&fmt=m4a3`), 400);
  assert.equal(await statusOf(side.url('ok-b', 'start=0&end=4', 'bad%0Atoken')), 401);
  assert.equal(await statusOf(`${side.base}/transcode?item=${apiKey}%0Ainjected&file=1&fmt=m4a3&start=${session}&token=${session}`), 400);

  await until(() => side.lines().length === 8, 'one log line per request');
  await sleep(200);   // let any late ffmpeg stderr arrive
  assert.equal(side.lines().length, 8);
  assert.match(timingOut.lineFor('stall-a'), /^transcode status=504 /);
  for (const secret of [session, 'ACCESS-TOKEN-SECRET', apiKey, 'injected', 'token=']) {
    assert.ok(!side.output.text.includes(secret), `logs must not contain ${secret}`);
    assert.ok(!timingOut.output.text.includes(secret), `logs must not contain ${secret}`);
  }
  assert.ok(session.length > 8, 'the session id should be a real value to search for');
  assert.match(side.lineFor('ok-a'), /^transcode status=200 .* range=0-4 clientGone=false$/);
  assert.match(side.lineFor('denied-a'), /^transcode status=401 /);
  assert.match(side.lines().at(-1), /^transcode status=400 .* item=- file=1 range=--- clientGone=false$/);
});

test('a negative inode reaches ABS unchanged, while start and end stay non-negative', { skip: !hasFfmpeg }, async () => {
  // Node reports inodes above 2^63 as negative (rclone/FUSE mounts), and ABS
  // uses that string as the file id.
  const ino = '-7463524515094582699';
  const abs = await startAbs('unused');
  const side = await startSidecar(abs.port);
  const transcode = async (query) => {
    const response = await fetch(`${side.base}/transcode?item=ok-neg&fmt=m4a3&token=test-api-key&${query}`);
    return { status: response.status, body: Buffer.from(await response.arrayBuffer()) };
  };

  const ok = await transcode(`file=${ino}&start=0&end=4`);
  assert.equal(ok.status, 200);
  assert.ok(ok.body.length > 0);
  assert.ok(abs.files.length > 0 && abs.files.every((file) => file === ino), `ABS saw ${abs.files}`);
  await until(() => side.lineFor('ok-neg'), 'the transcode log line');
  assert.match(side.lineFor('ok-neg'), new RegExp(`^transcode status=200 .* file=${ino} range=0-4 `));

  const fetched = abs.files.length;
  for (const file of ['--1', '1-2', '-', '+1', '1.5', '123456789012345678901']) {
    assert.equal((await transcode(`file=${encodeURIComponent(file)}&start=0&end=4`)).status, 400, `file=${file}`);
  }
  for (const range of ['start=-5&end=4', 'start=0&end=-4']) {
    const bad = await transcode(`file=${ino}&${range}`);
    assert.equal(bad.status, 400, range);
    assert.equal(bad.body.toString(), 'bad range');
  }
  assert.equal((await transcode(`file=${ino}&start=0&end=4&speed=-100`)).status, 400);
  assert.equal(abs.files.length, fetched, 'rejected requests must not reach ABS');
});
