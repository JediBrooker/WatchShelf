// WatchShelf sidecar. The watch can't download giant audiobook files whole, so
// this cuts small on-demand chunks with ffmpeg (via HTTP Range - it never pulls
// the whole file), and serves lean lists (books, authors, series, collections,
// per-book files) so nothing overflows the watch. Auth = the watch's own ABS
// token (?token=). Only required env: ABS_URL.
//
// Routes:
//   GET /health
//   POST /login?  {username,password}   -> {user:{token}} (proxied to ABS /login)
//   GET /libraries?token                -> {libraries:[{id,name}]}
//   GET /list?lib&token[&author=id|&series=id|&collection=id]  -> {books:[{id,title,author}]}
//   GET /authors?lib&token       -> {authors:[{id,name,count}]}
//   GET /series?lib&token        -> {series:[{id,name,count}]}
//   GET /collections?lib&token   -> {collections:[{id,name}]}
//   GET /files?item&token        -> {title,author,files:[{ino,duration,size,codec}]}
//   GET /transcode?item&file&fmt&start&end&token -> a small audio chunk
//   GET /cover?item&token[&w]    -> the book's cover image (JPEG, resized by ABS)
//   POST /progress?token  {itemId,currentTime,duration} -> real PATCH to ABS

import http from 'node:http';
import { spawn } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { readFile, readdir, unlink } from 'node:fs/promises';

const ABS  = (process.env.ABS_URL || '').replace(/\/+$/, '');
const PORT = Number(process.env.PORT || 8081);
// Mount prefix. cloudflared (and some proxies) forward it unchanged; we strip it so
// routes match. A prefix-stripping proxy (Caddy handle_path) sends bare /list, which
// also works. Set BASE_PATH='' to disable if your proxy already strips.
const BASE_PATH = (process.env.BASE_PATH ?? '/watchshelf-transcode').replace(/\/+$/, '');
const UA   = 'WatchShelf-sidecar';
if (!ABS) { console.error('ABS_URL is required (e.g. http://127.0.0.1:13378)'); process.exit(1); }

// fmt values double as the watch/sidecar PROTOCOL VERSION guard: the watch
// (b29+) requests fmt=m4a2; an older sidecar has no such CT entry and 400s,
// so a stale sidecar fails the sync visibly instead of feeding raw ADTS that
// the watch would mis-cache as ENCODING_M4A (silent cache poisoning). 'm4a'
// keeps the legacy ADTS behavior so older watch builds stay correct too.
const CT   = { mp3: 'audio/mpeg', m4a: 'audio/aac', m4a2: 'audio/mp4' };
const IDRE = /^[A-Za-z0-9_\-]+$/, NUM = /^[0-9]+$/;
const b64  = (s) => Buffer.from(String(s)).toString('base64');
const bearer = (t) => ({ Authorization: `Bearer ${t}`, 'User-Agent': UA });
const jsonHead = { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' };
// Error responses on JSON endpoints must BE JSON: the watch declares a JSON
// responseType, and a plain-text/HTML error body surfaces on-device as the
// opaque parse error -400 (INVALID_HTTP_BODY_IN_NETWORK_RESPONSE) instead of
// the real HTTP status - which masked an ABS 401 as "-400" in the field.
const fail = (res, code, msg) => { res.writeHead(code, jsonHead).end(JSON.stringify({ error: msg })); };

function ffArgs(srcUrl, token, fmt, start, end, out) {
  const a = ['-hide_banner', '-loglevel', 'error', '-user_agent', UA,
    '-headers', `Authorization: Bearer ${token}\r\n`,
    '-reconnect', '1', '-reconnect_streamed', '1', '-reconnect_delay_max', '2'];
  if (start != null) { a.push('-ss', String(start)); }
  a.push('-i', srcUrl);
  if (start != null && end != null) { a.push('-t', String(Math.max(0, Number(end) - Number(start)))); }
  else if (end != null)            { a.push('-to', String(end)); }
  // Strip every inherited metadata field (title/author/comments/cover art/etc.) -
  // WatchShelf doesn't need it embedded (book metadata lives server-side), and a
  // Garmin-confirmed bug (certain characters, e.g. (c) or curly quotes, in MP3
  // ID3 text frames) silently breaks native playback on real hardware with no
  // error surfaced to the app. -id3v2_version 0 additionally suppresses ffmpeg's
  // own default encoder tag, so the mp3 output carries no ID3 tag at all.
  a.push('-map_metadata', '-1', '-id3v2_version', '0');
  // Always TRANSCODE to AAC (not stream-copy) regardless of source codec -
  // "always re-encode to a known-good target", so any book (mp3-sourced or
  // aac-sourced) lands in the same format. m4a2 is a REAL M4A/MP4 container
  // (-f ipod), NOT raw ADTS: Connect IQ has no API for an app to tell the
  // native player a track's duration - the player derives it by parsing the
  // cached file, and a bare ADTS frame stream carries no total-duration field
  // anywhere, which is exactly why the player showed no elapsed/total time
  // indicator. The MP4 moov atom carries exact duration + sample tables, so
  // the position bar works. The mp4 muxer needs seekable output (moov is
  // finalized at the end; +faststart then rewrites it to the front), so this
  // branch writes to a temp file (`out`) instead of pipe:1 - transcode()
  // already buffers fully anyway.
  if (fmt === 'm4a2') { a.push('-map', '0:a:0', '-c:a', 'aac', '-b:a', '96k', '-ac', '1', '-ar', '44100', '-movflags', '+faststart', '-f', 'ipod', out); }
  // Legacy ADTS for watch builds <= b28, which cache this as ENCODING_ADTS.
  else if (fmt === 'm4a') { a.push('-map', '0:a:0', '-c:a', 'aac', '-b:a', '96k', '-ac', '1', '-ar', '44100', '-f', 'adts', 'pipe:1'); }
  // 44100Hz/96kbps instead of the original 22050Hz/64kbps: the file itself was
  // independently verified valid, complete, standard MP3 (clean full decode,
  // correct headers) - but 22050Hz mono is a much less common combination than
  // typical commercial audio, a plausible edge case for Garmin's specific
  // hardware decoder to not handle even though it's fully spec-compliant.
  // Mono is kept (legitimate, common for spoken word, and halves file size vs
  // stereo for no perceptual benefit on speech) - only sample rate/bitrate move
  // to more mainstream values.
  else { a.push('-map', '0:a:0', '-c:a', 'libmp3lame', '-b:a', '96k', '-ac', '1', '-ar', '44100', '-f', 'mp3', 'pipe:1'); }
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

  // m4a writes a REAL MP4 container to a temp file (the mp4 muxer needs
  // seekable output for the moov atom - see ffArgs), then serves the file
  // whole. mp3 still streams from ffmpeg's stdout. Both paths buffer the full
  // chunk before responding: the watch's audio downloader needs a real
  // Content-Length up front - a chunked, size-unknown response can leave the
  // OS with a file it can't validate/size correctly, which surfaces as a
  // native "Media Error Occurred" well after the download itself already
  // reported success to the app.
  if (fmt === 'm4a2') {
    const out = join(tmpdir(), `watchshelf-${randomUUID()}.m4a`);
    const drop = () => unlink(out).catch(() => {});
    const ff = spawn('ffmpeg', ffArgs(src, token, fmt, start, end, out), { stdio: ['ignore', 'ignore', 'inherit'] });
    let done = false;
    req.on('close', () => { if (!done) { done = true; ff.kill('SIGKILL'); drop(); } });
    ff.on('error', () => {
      if (done) { return; }
      done = true;
      drop();
      if (!res.headersSent) { res.writeHead(502).end('ffmpeg error'); }
    });
    ff.on('close', async (code) => {
      if (done) { return; }
      done = true;
      if (code !== 0) { drop(); if (!res.headersSent) { res.writeHead(502).end('transcode failed'); } return; }
      try {
        const buf = await readFile(out);
        res.writeHead(200, { 'Content-Type': CT[fmt], 'Content-Length': buf.length, 'Cache-Control': 'no-store' });
        res.end(buf);
      } catch (e) {
        if (!res.headersSent) { res.writeHead(502).end('transcode read failed'); }
      }
      drop();
    });
    return;
  }

  const ff = spawn('ffmpeg', ffArgs(src, token, fmt, start, end, null), { stdio: ['ignore', 'pipe', 'inherit'] });
  const parts = [];
  let done = false;
  ff.stdout.on('data', (c) => parts.push(c));
  req.on('close', () => { if (!done) { done = true; ff.kill('SIGKILL'); } });
  ff.on('error', () => {
    if (done) { return; }
    done = true;
    if (!res.headersSent) { res.writeHead(502).end('ffmpeg error'); }
  });
  ff.on('close', (code) => {
    if (done) { return; }
    done = true;
    if (code !== 0) { if (!res.headersSent) { res.writeHead(502).end('transcode failed'); } return; }
    const buf = Buffer.concat(parts);
    res.writeHead(200, { 'Content-Type': CT[fmt], 'Content-Length': buf.length, 'Cache-Control': 'no-store' });
    res.end(buf);
  });
}

// GET /cover?item&token[&w] -> the book's cover, resized by ABS itself
// (format=jpeg keeps the payload small and universally decodable). The watch
// fetches this via Communications.makeImageRequest, which cannot send custom
// headers - hence ?token= auth, same as every other watch-facing route. Garmin
// Connect Mobile downscales/dithers the image for the device, so `w` only
// bounds what ABS ships over the wire.
async function cover(req, res, u) {
  const item = u.searchParams.get('item'), token = u.searchParams.get('token');
  const w = u.searchParams.get('w') || '256';
  if (!item || !token || !IDRE.test(item) || !NUM.test(w)) { res.writeHead(400).end('bad params'); return; }
  try {
    const r = await fetch(`${ABS}/api/items/${encodeURIComponent(item)}/cover?format=jpeg&width=${w}`, { headers: bearer(token) });
    if (!r.ok) { res.writeHead(r.status === 404 ? 404 : 502).end('ABS ' + r.status); return; }
    const buf = Buffer.from(await r.arrayBuffer());
    res.writeHead(200, { 'Content-Type': r.headers.get('content-type') || 'image/jpeg', 'Content-Length': buf.length, 'Cache-Control': 'no-store' });
    res.end(buf);
  } catch (e) { res.writeHead(502).end('ABS unreachable'); }
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
  if (!lib || !token || !IDRE.test(lib)) { fail(res, 400, 'bad params'); return; }
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
  } catch (e) { fail(res, 502, String(e.message || 'ABS')); }
}

async function groups(req, res, u, path, map) {
  const lib = u.searchParams.get('lib'), token = u.searchParams.get('token');
  if (!lib || !token || !IDRE.test(lib)) { fail(res, 400, 'bad params'); return; }
  try {
    const d = await absJson(`/api/libraries/${encodeURIComponent(lib)}/${path}`, token);
    res.writeHead(200, jsonHead).end(JSON.stringify(map(d)));
  } catch (e) { fail(res, 502, String(e.message || 'ABS')); }
}
const authors     = (q, s, u) => groups(q, s, u, 'authors', (d) => ({ authors: (d.authors || []).map((a) => ({ id: a.id, name: a.name, count: a.numBooks })).sort((x, y) => String(x.name).localeCompare(String(y.name))) }));
const series      = (q, s, u) => groups(q, s, u, 'series?limit=1000', (d) => ({ series: (d.results || []).map((x) => ({ id: x.id, name: x.name, count: (x.books || []).length })) }));
const collections = (q, s, u) => groups(q, s, u, 'collections', (d) => ({ collections: (d.results || []).map((c) => ({ id: c.id, name: c.name })) }));

async function files(req, res, u) {
  const item = u.searchParams.get('item'), token = u.searchParams.get('token');
  if (!item || !token || !IDRE.test(item)) { fail(res, 400, 'bad params'); return; }
  try {
    const m = (await absJson(`/api/items/${encodeURIComponent(item)}?expanded=1`, token)).media || {};
    const out = {
      title: (m.metadata || {}).title || 'Book',
      author: (m.metadata || {}).authorName || '',
      files: (m.audioFiles || []).map((a) => ({ ino: a.ino, duration: a.duration, size: (a.metadata || {}).size || a.size || 0, codec: a.codec })),
    };
    res.writeHead(200, jsonHead).end(JSON.stringify(out));
  } catch (e) { fail(res, 502, String(e.message || 'ABS')); }
}

function readJson(req, cb) {
  let b = '', over = false;
  req.on('data', (c) => { b += c; if (b.length > 8192) { over = true; req.destroy(); } });
  req.on('end', () => { if (over) { return cb(null); } try { cb(JSON.parse(b || '{}')); } catch (e) { cb(null); } });
  req.on('error', () => cb(null));
}

function progress(req, res, u) {
  const token = u.searchParams.get('token');
  if (!token) { fail(res, 400, 'bad params'); return; }
  readJson(req, async (body) => {
    if (!body || typeof body.itemId !== 'string' || !IDRE.test(body.itemId) || typeof body.currentTime !== 'number') { fail(res, 400, 'bad body'); return; }
    const payload = { currentTime: body.currentTime };
    if (typeof body.duration === 'number' && body.duration > 0) { payload.duration = body.duration; payload.progress = Math.min(1, body.currentTime / body.duration); }
    try {
      const r = await fetch(`${ABS}/api/me/progress/${encodeURIComponent(body.itemId)}`,
        { method: 'PATCH', headers: { ...bearer(token), 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
      if (r.ok) { res.writeHead(200, jsonHead).end(JSON.stringify({ ok: true })); } else { fail(res, 502, 'ABS ' + r.status); }
    } catch (e) { res.writeHead(502).end('ABS unreachable'); }
  });
}

// POST /login {username,password} -> proxy to ABS /login, return a slim {user:{token}}.
// Lets the watch talk to ONLY the sidecar; ABS can stay fully internal.
function login(req, res) {
  readJson(req, async (body) => {
    if (!body || typeof body.username !== 'string' || typeof body.password !== 'string') { fail(res, 400, 'bad body'); return; }
    try {
      const r = await fetch(`${ABS}/login`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'User-Agent': UA },
        body: JSON.stringify({ username: body.username, password: body.password }),
      });
      if (!r.ok) { fail(res, r.status === 401 ? 401 : 502, 'login ' + r.status); return; }
      const u = (((await r.json()) || {}).user || {});
      // ABS >= 2.26 issues a JWT accessToken at login; the legacy static
      // user.token is deprecated there and updated servers REJECT it for API
      // calls even though login still echoes it - the watch then 401s on its
      // very first call after a "successful" login. Prefer the new token,
      // fall back to the legacy field for older servers.
      const token = u.accessToken || u.token;
      if (!token) { fail(res, 502, 'no token'); return; }
      res.writeHead(200, jsonHead).end(JSON.stringify({ user: { token } }));
    } catch (e) { fail(res, 502, 'ABS unreachable'); }
  });
}

// GET /libraries?token -> slim {libraries:[{id,name,mediaType}]} (proxied from
// ABS /api/libraries). mediaType is passed through - the watch uses it to skip
// podcast libraries and only list book libraries.
async function libraries(req, res, u) {
  const token = u.searchParams.get('token');
  if (!token) { fail(res, 400, 'bad params'); return; }
  try {
    const d = await absJson('/api/libraries', token);
    res.writeHead(200, jsonHead).end(JSON.stringify({ libraries: (d.libraries || []).map((l) => ({ id: l.id, name: l.name, mediaType: l.mediaType })) }));
  } catch (e) { fail(res, 502, String(e.message || 'ABS')); }
}

const server = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  let p = u.pathname;
  if (BASE_PATH && p.startsWith(BASE_PATH)) { p = p.slice(BASE_PATH.length) || '/'; }
  const g = req.method === 'GET';
  // CONTRACT: the watch's login preflight requires status 200, Content-Type
  // text/plain, and a body of EXACTLY "ok" (no newline) - it is how the app
  // distinguishes a WatchShelf sidecar from anything else (e.g. the ABS
  // server itself) before sending credentials anywhere. Don't change any of
  // the three without updating Login.mc.
  if (p === '/health') { res.writeHead(200, { 'Content-Type': 'text/plain' }).end('ok'); return; }
  if (p === '/login'       && req.method === 'POST') { login(req, res); return; }
  if (p === '/libraries'   && g) { libraries(req, res, u); return; }
  if (p === '/list'        && g) { list(req, res, u); return; }
  if (p === '/authors'     && g) { authors(req, res, u); return; }
  if (p === '/series'      && g) { series(req, res, u); return; }
  if (p === '/collections' && g) { collections(req, res, u); return; }
  if (p === '/files'       && g) { files(req, res, u); return; }
  if (p === '/transcode'   && g) { transcode(req, res, u); return; }
  if (p === '/cover'       && g) { cover(req, res, u); return; }
  if (p === '/progress'    && req.method === 'POST') { progress(req, res, u); return; }
  res.writeHead(404).end();
});
// Sweep temp files stranded by a previous process death (docker restart,
// OOM-kill): the per-request cleanup handlers can't run when the whole
// process dies, ffmpeg finishes into the temp file anyway, and container
// /tmp is never auto-cleaned - they'd accumulate across restarts forever.
readdir(tmpdir()).then((names) => {
  for (const n of names) {
    if (n.startsWith('watchshelf-') && n.endsWith('.m4a')) { unlink(join(tmpdir(), n)).catch(() => {}); }
  }
}).catch(() => {});

const BIND = process.env.BIND || '127.0.0.1';
server.listen(PORT, BIND, () => console.log(`WatchShelf sidecar ${BIND}:${PORT} -> ${ABS}`));
