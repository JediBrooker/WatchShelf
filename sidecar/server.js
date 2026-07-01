// WatchShelf sidecar. The watch can't download giant audiobook files whole, so
// this cuts small on-demand chunks with ffmpeg (via HTTP Range - it never pulls
// the whole file), and serves a lean file list for books whose ABS detail is too
// big for the watch to accept.
//
// Auth: the watch passes its OWN ABS token as ?token=, which the sidecar uses to
// read from ABS - no separate secret to configure. The only required env is
// ABS_URL (point it at ABS's INTERNAL address to bypass Cloudflare, e.g.
// http://127.0.0.1:13378).
//
// Routes:
//   GET /health
//   GET /files?item=<id>&token=<absToken>
//        -> {"title":"...","files":[{"ino":N,"duration":S,"size":B,"codec":"mp3"}]}
//   GET /transcode?item=<id>&file=<ino>&fmt=mp3|m4a&start=<s>&end=<s>&token=<absToken>
//        -> a small mp3 (or ADTS) chunk.

import http from 'node:http';
import { spawn } from 'node:child_process';
import { pipeline } from 'node:stream/promises';

const ABS  = (process.env.ABS_URL || '').replace(/\/+$/, '');
const PORT = Number(process.env.PORT || 8081);
const UA   = 'WatchShelf-sidecar';
if (!ABS) { console.error('ABS_URL is required (e.g. http://127.0.0.1:13378)'); process.exit(1); }

const CT  = { mp3: 'audio/mpeg', m4a: 'audio/aac' };
const IDRE = /^[A-Za-z0-9_\-]+$/, NUM = /^[0-9]+$/;

function ffArgs(srcUrl, token, fmt, start, end) {
  const a = ['-hide_banner', '-loglevel', 'error', '-user_agent', UA,
    '-headers', `Authorization: Bearer ${token}\r\n`,
    '-reconnect', '1', '-reconnect_streamed', '1', '-reconnect_delay_max', '2'];
  if (start != null) { a.push('-ss', String(start)); }
  a.push('-i', srcUrl);
  if (start != null && end != null) { a.push('-t', String(Math.max(0, Number(end) - Number(start)))); }
  else if (end != null)            { a.push('-to', String(end)); }
  if (fmt === 'm4a') { a.push('-map', '0:a:0', '-c:a', 'copy', '-f', 'adts', 'pipe:1'); }
  else { a.push('-map', '0:a:0', '-c:a', 'libmp3lame', '-b:a', '64k', '-ac', '1', '-ar', '22050', '-f', 'mp3', 'pipe:1'); }
  return a;
}

function transcode(req, res, u) {
  const item = u.searchParams.get('item'), file = u.searchParams.get('file');
  const fmt = (u.searchParams.get('fmt') || 'mp3').toLowerCase();
  const start = u.searchParams.get('start'), end = u.searchParams.get('end');
  const token = u.searchParams.get('token');
  if (!item || !file || !token || !CT[fmt] || !IDRE.test(item) || !NUM.test(file)) { res.writeHead(400).end('bad params'); return; }
  if ((start != null && !NUM.test(start)) || (end != null && !NUM.test(end))) { res.writeHead(400).end('bad range'); return; }
  const src = `${ABS}/api/items/${encodeURIComponent(item)}/file/${encodeURIComponent(file)}/download`;
  const ff = spawn('ffmpeg', ffArgs(src, token, fmt, start, end), { stdio: ['ignore', 'pipe', 'inherit'] });
  res.writeHead(200, { 'Content-Type': CT[fmt], 'Cache-Control': 'no-store' });
  ff.on('error', () => { if (!res.writableEnded) res.destroy(); });
  req.on('close', () => ff.kill('SIGKILL'));
  pipeline(ff.stdout, res).catch(() => { ff.kill('SIGKILL'); if (!res.writableEnded) res.destroy(); });
}

async function files(req, res, u) {
  const item = u.searchParams.get('item'), token = u.searchParams.get('token');
  if (!item || !token || !IDRE.test(item)) { res.writeHead(400).end('bad params'); return; }
  try {
    const r = await fetch(`${ABS}/api/items/${encodeURIComponent(item)}?expanded=1`,
      { headers: { Authorization: `Bearer ${token}`, 'User-Agent': UA } });
    if (!r.ok) { res.writeHead(502).end('ABS ' + r.status); return; }
    const d = await r.json();
    const m = d.media || {};
    const out = {
      title: (m.metadata || {}).title || 'Book',
      files: (m.audioFiles || []).map((a) => ({
        ino: a.ino, duration: a.duration, size: (a.metadata || {}).size || a.size || 0, codec: a.codec,
      })),
    };
    res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }).end(JSON.stringify(out));
  } catch (e) { res.writeHead(502).end('ABS unreachable'); }
}

async function list(req, res, u) {
  const lib = u.searchParams.get('lib'), token = u.searchParams.get('token');
  if (!lib || !token || !IDRE.test(lib)) { res.writeHead(400).end('bad params'); return; }
  try {
    const r = await fetch(`${ABS}/api/libraries/${encodeURIComponent(lib)}/items?minified=1&limit=1000&sort=media.metadata.title`,
      { headers: { Authorization: `Bearer ${token}`, 'User-Agent': UA } });
    if (!r.ok) { res.writeHead(502).end('ABS ' + r.status); return; }
    const d = await r.json();
    const out = (d.results || []).map((it) => ({
      id: it.id,
      title: ((it.media || {}).metadata || {}).title || '?',
      author: ((it.media || {}).metadata || {}).authorName || '',
    }));
    res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }).end(JSON.stringify({ books: out }));
  } catch (e) { res.writeHead(502).end('ABS unreachable'); }
}

function readJson(req, cb) {
  let b = '', over = false;
  req.on('data', (c) => { b += c; if (b.length > 8192) { over = true; req.destroy(); } });
  req.on('end', () => { if (over) { return cb(null); } try { cb(JSON.parse(b || '{}')); } catch (e) { cb(null); } });
  req.on('error', () => cb(null));
}

function progress(req, res, u) {
  const token = u.searchParams.get('token');
  if (!token) { res.writeHead(400).end('bad params'); return; }
  readJson(req, async (body) => {
    if (!body || typeof body.itemId !== 'string' || !IDRE.test(body.itemId) || typeof body.currentTime !== 'number') { res.writeHead(400).end('bad body'); return; }
    const payload = { currentTime: body.currentTime };
    if (typeof body.duration === 'number' && body.duration > 0) { payload.duration = body.duration; payload.progress = Math.min(1, body.currentTime / body.duration); }
    try {
      const r = await fetch(`${ABS}/api/me/progress/${encodeURIComponent(body.itemId)}`,
        { method: 'PATCH', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', 'User-Agent': UA }, body: JSON.stringify(payload) });
      res.writeHead(r.ok ? 200 : 502).end(r.ok ? 'ok' : 'ABS ' + r.status);
    } catch (e) { res.writeHead(502).end('ABS unreachable'); }
  });
}

const server = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  if (u.pathname === '/health') { res.writeHead(200).end('ok'); return; }
  if (u.pathname === '/list'      && req.method === 'GET') { list(req, res, u); return; }
  if (u.pathname === '/files'     && req.method === 'GET') { files(req, res, u); return; }
  if (u.pathname === '/transcode' && req.method === 'GET') { transcode(req, res, u); return; }
  if (u.pathname === '/progress'  && req.method === 'POST') { progress(req, res, u); return; }
  res.writeHead(404).end();
});
const BIND = process.env.BIND || '127.0.0.1';
server.listen(PORT, BIND, () => console.log(`WatchShelf sidecar ${BIND}:${PORT} -> ${ABS}`));
