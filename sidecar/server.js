// WatchShelf sidecar: transcode + progress bridge for Audiobookshelf.
// Node 18+ (global fetch), no framework. Sits behind your reverse proxy on
// HTTPS:443 (or wherever the watch reaches it); binds localhost only.
//
// Routes:
//   GET  /transcode?item=&file=&fmt=mp3|m4a&start=&end=&key=
//        -> one complete audio body (mp3, or AAC copied to ADTS) the watch stores.
//           ffmpeg pulls the source from ABS over HTTP (Range-seekable) so it can
//           demux .m4b/.mp4 and cut a chapter without reading the whole book.
//   POST /progress?key=   body {itemId, currentTime, duration?}
//        -> forwards a REAL PATCH to ABS /api/me/progress/:id. The watch can't:
//           Monkey C has no PATCH method and ABS ignores X-HTTP-Method-Override.
//
// The ABS token stays server-side. Every ABS call sends a normal User-Agent so a
// Cloudflare/WAF in front of ABS doesn't 403 it as a bot.

import http from 'node:http';
import { spawn } from 'node:child_process';
import { pipeline } from 'node:stream/promises';

const ABS         = (process.env.ABS_URL || '').replace(/\/+$/, ''); // prefer internal, e.g. http://127.0.0.1:13378
const ABS_TOKEN   = process.env.ABS_TOKEN;    // ABS long-lived API key
const SIDECAR_KEY = process.env.SIDECAR_KEY;  // shared secret the watch must send
const PORT        = Number(process.env.PORT || 8081);
const UA          = 'WatchShelf-sidecar';

if (!ABS || !ABS_TOKEN || !SIDECAR_KEY) {
  console.error('Missing env: ABS_URL, ABS_TOKEN, SIDECAR_KEY are required. See .env.example');
  process.exit(1);
}

// Content-Type must match the watch's declared :mediaEncoding.
const CT = { mp3: 'audio/mpeg', m4a: 'audio/aac' };

function ffArgs(srcUrl, fmt, start, end) {
  const args = ['-hide_banner', '-loglevel', 'error',
    '-user_agent', UA,
    '-headers', `Authorization: Bearer ${ABS_TOKEN}\r\n`,
    '-reconnect', '1', '-reconnect_streamed', '1', '-reconnect_delay_max', '2'];
  if (start != null) { args.push('-ss', String(start)); }
  args.push('-i', srcUrl);
  if (start != null && end != null) { args.push('-t', String(Math.max(0, Number(end) - Number(start)))); }
  else if (end != null)            { args.push('-to', String(end)); }
  if (fmt === 'm4a') {
    args.push('-map', '0:a:0', '-c:a', 'copy', '-f', 'adts', 'pipe:1');       // lossless AAC -> ADTS
  } else {
    args.push('-map', '0:a:0', '-c:a', 'libmp3lame', '-b:a', '64k', '-ac', '1', '-ar', '22050', '-f', 'mp3', 'pipe:1');
  }
  return args;
}

function transcode(req, res, u) {
  if (u.searchParams.get('key') !== SIDECAR_KEY) { res.writeHead(401).end(); return; }
  const item  = u.searchParams.get('item');
  const file  = u.searchParams.get('file');
  const fmt   = (u.searchParams.get('fmt') || 'mp3').toLowerCase();
  const start = u.searchParams.get('start');
  const end   = u.searchParams.get('end');
  if (!item || !file || !CT[fmt] || !/^[A-Za-z0-9_\-]+$/.test(item) || !/^[0-9]+$/.test(file)) {
    res.writeHead(400).end('bad params'); return;
  }
  if ((start != null && !/^[0-9]+$/.test(start)) || (end != null && !/^[0-9]+$/.test(end))) {
    res.writeHead(400).end('bad range'); return;
  }
  const srcUrl = `${ABS}/api/items/${encodeURIComponent(item)}/file/${encodeURIComponent(file)}/download`;
  const ff = spawn('ffmpeg', ffArgs(srcUrl, fmt, start, end), { stdio: ['ignore', 'pipe', 'inherit'] });
  res.writeHead(200, { 'Content-Type': CT[fmt], 'Cache-Control': 'no-store' });
  ff.on('error', () => { if (!res.writableEnded) res.destroy(); });
  req.on('close', () => { ff.kill('SIGKILL'); }); // watch aborted -> stop ffmpeg
  pipeline(ff.stdout, res).catch(() => { ff.kill('SIGKILL'); if (!res.writableEnded) res.destroy(); });
}

function readJson(req, cb) {
  let b = '', over = false;
  req.on('data', (c) => { b += c; if (b.length > 65536) { over = true; req.destroy(); } });
  req.on('end', () => { if (over) { return cb(null); } try { cb(JSON.parse(b || '{}')); } catch (e) { cb(null); } });
  req.on('error', () => cb(null));
}

function progress(req, res, u) {
  if (u.searchParams.get('key') !== SIDECAR_KEY) { res.writeHead(401).end(); return; }
  readJson(req, async (body) => {
    if (!body || typeof body.itemId !== 'string' || !/^[A-Za-z0-9_\-]+$/.test(body.itemId)
        || typeof body.currentTime !== 'number') { res.writeHead(400).end('bad body'); return; }
    const payload = { currentTime: body.currentTime };
    if (typeof body.duration === 'number' && body.duration > 0) {
      payload.duration = body.duration;
      payload.progress = Math.min(1, body.currentTime / body.duration);
    }
    try {
      const abs = await fetch(`${ABS}/api/me/progress/${encodeURIComponent(body.itemId)}`, {
        method: 'PATCH',
        headers: { 'Authorization': `Bearer ${ABS_TOKEN}`, 'Content-Type': 'application/json', 'User-Agent': UA },
        body: JSON.stringify(payload),
      });
      res.writeHead(abs.ok ? 200 : 502).end(abs.ok ? 'OK' : `ABS ${abs.status}`);
    } catch (e) {
      res.writeHead(502).end('ABS unreachable');
    }
  });
}

const server = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  if (u.pathname === '/transcode' && req.method === 'GET')  { transcode(req, res, u); return; }
  if (u.pathname === '/progress'  && req.method === 'POST') { progress(req, res, u);  return; }
  res.writeHead(404).end();
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`WatchShelf sidecar on http://127.0.0.1:${PORT} -> ${ABS}`);
});
