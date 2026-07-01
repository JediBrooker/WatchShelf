// WatchShelf sidecar. The watch can't download giant audiobook files whole, so
// this cuts small on-demand chunks with ffmpeg (via HTTP Range - it never pulls
// the whole file), and serves lean lists (books, authors, series, collections,
// per-book files) so nothing overflows the watch. Auth = the watch's own ABS
// token (?token=). Only required env: ABS_URL.
//
// Routes:
//   GET /health
//   GET /list?lib&token[&author=id|&series=id|&collection=id]  -> {books:[{id,title,author}]}
//   GET /authors?lib&token       -> {authors:[{id,name,count}]}
//   GET /series?lib&token        -> {series:[{id,name,count}]}
//   GET /collections?lib&token   -> {collections:[{id,name}]}
//   GET /files?item&token        -> {title,files:[{ino,duration,size,codec}]}
//   GET /transcode?item&file&fmt&start&end&token -> a small mp3 chunk
//   POST /progress?token  {itemId,currentTime,duration} -> real PATCH to ABS

import http from 'node:http';
import { spawn } from 'node:child_process';
import { pipeline } from 'node:stream/promises';

const ABS  = (process.env.ABS_URL || '').replace(/\/+$/, '');
const PORT = Number(process.env.PORT || 8081);
const UA   = 'WatchShelf-sidecar';
if (!ABS) { console.error('ABS_URL is required (e.g. http://127.0.0.1:13378)'); process.exit(1); }

const CT   = { mp3: 'audio/mpeg', m4a: 'audio/aac' };
const IDRE = /^[A-Za-z0-9_\-]+$/, NUM = /^[0-9]+$/;
const b64  = (s) => Buffer.from(String(s)).toString('base64');
const bearer = (t) => ({ Authorization: `Bearer ${t}`, 'User-Agent': UA });
const jsonHead = { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' };

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

const bookOf = (it) => ({
  id: it.id,
  title: ((it.media || {}).metadata || {}).title || '?',
  author: ((it.media || {}).metadata || {}).authorName || '',
});

async function absJson(path, token) {
  const r = await fetch(`${ABS}${path}`, { headers: bearer(token) });
  if (!r.ok) { const e = new Error('ABS ' + r.status); e.status = r.status; throw e; }
  return r.json();
}

async function list(req, res, u) {
  const lib = u.searchParams.get('lib'), token = u.searchParams.get('token');
  const author = u.searchParams.get('author'), series = u.searchParams.get('series'), collection = u.searchParams.get('collection');
  if (!lib || !token || !IDRE.test(lib)) { res.writeHead(400).end('bad params'); return; }
  try {
    let books;
    if (collection && IDRE.test(collection)) {
      books = ((await absJson(`/api/collections/${encodeURIComponent(collection)}`, token)).books || []).map(bookOf);
    } else {
      let filter = '';
      if (author && IDRE.test(author)) { filter = `&filter=authors.${b64(author)}`; }
      else if (series && IDRE.test(series)) { filter = `&filter=series.${b64(series)}`; }
      books = ((await absJson(`/api/libraries/${encodeURIComponent(lib)}/items?minified=1&limit=1000&sort=media.metadata.title${filter}`, token)).results || []).map(bookOf);
    }
    res.writeHead(200, jsonHead).end(JSON.stringify({ books }));
  } catch (e) { res.writeHead(502).end(String(e.message || 'ABS')); }
}

async function groups(req, res, u, path, map) {
  const lib = u.searchParams.get('lib'), token = u.searchParams.get('token');
  if (!lib || !token || !IDRE.test(lib)) { res.writeHead(400).end('bad params'); return; }
  try {
    const d = await absJson(`/api/libraries/${encodeURIComponent(lib)}/${path}`, token);
    res.writeHead(200, jsonHead).end(JSON.stringify(map(d)));
  } catch (e) { res.writeHead(502).end(String(e.message || 'ABS')); }
}
const authors     = (q, s, u) => groups(q, s, u, 'authors', (d) => ({ authors: (d.authors || []).map((a) => ({ id: a.id, name: a.name, count: a.numBooks })).sort((x, y) => String(x.name).localeCompare(String(y.name))) }));
const series      = (q, s, u) => groups(q, s, u, 'series?limit=1000', (d) => ({ series: (d.results || []).map((x) => ({ id: x.id, name: x.name, count: (x.books || []).length })) }));
const collections = (q, s, u) => groups(q, s, u, 'collections', (d) => ({ collections: (d.results || []).map((c) => ({ id: c.id, name: c.name })) }));

async function files(req, res, u) {
  const item = u.searchParams.get('item'), token = u.searchParams.get('token');
  if (!item || !token || !IDRE.test(item)) { res.writeHead(400).end('bad params'); return; }
  try {
    const m = (await absJson(`/api/items/${encodeURIComponent(item)}?expanded=1`, token)).media || {};
    const out = {
      title: (m.metadata || {}).title || 'Book',
      files: (m.audioFiles || []).map((a) => ({ ino: a.ino, duration: a.duration, size: (a.metadata || {}).size || a.size || 0, codec: a.codec })),
    };
    res.writeHead(200, jsonHead).end(JSON.stringify(out));
  } catch (e) { res.writeHead(502).end(String(e.message || 'ABS')); }
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
        { method: 'PATCH', headers: { ...bearer(token), 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
      res.writeHead(r.ok ? 200 : 502).end(r.ok ? 'ok' : 'ABS ' + r.status);
    } catch (e) { res.writeHead(502).end('ABS unreachable'); }
  });
}

const server = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  const p = u.pathname, g = req.method === 'GET';
  if (p === '/health') { res.writeHead(200).end('ok'); return; }
  if (p === '/list'        && g) { list(req, res, u); return; }
  if (p === '/authors'     && g) { authors(req, res, u); return; }
  if (p === '/series'      && g) { series(req, res, u); return; }
  if (p === '/collections' && g) { collections(req, res, u); return; }
  if (p === '/files'       && g) { files(req, res, u); return; }
  if (p === '/transcode'   && g) { transcode(req, res, u); return; }
  if (p === '/progress'    && req.method === 'POST') { progress(req, res, u); return; }
  res.writeHead(404).end();
});
const BIND = process.env.BIND || '127.0.0.1';
server.listen(PORT, BIND, () => console.log(`WatchShelf sidecar ${BIND}:${PORT} -> ${ABS}`));
