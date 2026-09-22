import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const sidecarDir = fileURLToPath(new URL('../', import.meta.url));

const hasFfmpeg = spawnSync('ffmpeg', ['-version']).status === 0
  && spawnSync('ffprobe', ['-version']).status === 0;

function freePort() {
  return new Promise((resolvePort, reject) => {
    const socket = net.createServer();
    socket.once('error', reject);
    socket.listen(0, '127.0.0.1', () => {
      const { port } = socket.address();
      socket.close((error) => error ? reject(error) : resolvePort(port));
    });
  });
}

function listen(server) {
  return new Promise((resolveListen, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolveListen);
  });
}

function close(server) {
  return new Promise((resolveClose) => server.close(resolveClose));
}

async function waitForHealth(port) {
  for (let attempt = 0; attempt < 50; attempt += 1) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/health`);
      if (response.ok && await response.text() === 'ok') return;
    } catch {}
    await new Promise((resolveWait) => setTimeout(resolveWait, 100));
  }
  throw new Error('sidecar did not become ready');
}

test('transcodes supported speeds and rejects unsupported ones', { skip: !hasFfmpeg }, async () => {
  const work = mkdtempSync(join(tmpdir(), 'watchshelf-speed-test-'));
  const input = join(work, 'input.wav');
  const output = join(work, 'output.m4a');
  const generated = spawnSync('ffmpeg', [
    '-hide_banner', '-loglevel', 'error', '-f', 'lavfi',
    '-i', 'sine=frequency=440:duration=12', '-ar', '44100', input,
  ]);
  assert.equal(generated.status, 0, generated.stderr.toString());
  const audio = readFileSync(input);
  const jwt = [
    Buffer.from('{}').toString('base64url'),
    Buffer.from(JSON.stringify({ exp: Math.floor(Date.now() / 1000) + 3600 })).toString('base64url'),
    'sig',
  ].join('.');
  const absServer = http.createServer((req, res) => {
    if (req.method === 'POST' && req.url === '/login') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ user: { accessToken: jwt, username: 'test' } }));
      return;
    }
    if (req.method === 'GET' && req.url === '/api/items/book/file/1/download') {
      res.writeHead(200, { 'Content-Type': 'audio/wav', 'Content-Length': audio.length });
      res.end(audio);
      return;
    }
    res.writeHead(404).end();
  });
  await listen(absServer);
  const sidecarPort = await freePort();
  const sidecar = spawn('node', [join(sidecarDir, 'server.js')], {
    cwd: sidecarDir,
    env: { ...process.env, ABS_URL: `http://127.0.0.1:${absServer.address().port}`,
      BIND: '127.0.0.1', PORT: String(sidecarPort), BASE_PATH: '' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  try {
    await waitForHealth(sidecarPort);
    const login = await fetch(`http://127.0.0.1:${sidecarPort}/login`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: 'test', password: 'test' }),
    });
    assert.equal(login.status, 200);
    const sessionId = (await login.json()).user.token;
    for (const speed of [100, 125, 150, 175, 200]) {
      const encoded = await fetch(`http://127.0.0.1:${sidecarPort}/transcode?item=book&file=1&fmt=m4a3&start=2&end=6&speed=${speed}&token=${sessionId}`);
      assert.equal(encoded.status, 200);
      assert.equal(encoded.headers.get('content-type'), 'audio/mp4');
      writeFileSync(output, Buffer.from(await encoded.arrayBuffer()));
      const probe = spawnSync('ffprobe', [
        '-v', 'error', '-show_entries', 'format=duration', '-of', 'default=nw=1:nk=1', output,
      ]);
      assert.equal(probe.status, 0, probe.stderr.toString());
      const duration = Number(probe.stdout.toString().trim());
      const expected = 4 / (speed / 100);
      assert.ok(Math.abs(duration - expected) < 0.2,
        `expected about ${expected}s at ${speed}%, received ${duration}s`);
    }
    const invalid = await fetch(`http://127.0.0.1:${sidecarPort}/transcode?item=book&file=1&fmt=m4a3&start=2&end=6&speed=130&token=${sessionId}`);
    assert.equal(invalid.status, 400);
  } finally {
    sidecar.kill('SIGTERM');
    await close(absServer);
    rmSync(work, { recursive: true, force: true });
  }
});
