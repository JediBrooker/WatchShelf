// WatchShelf transcode sidecar.
// Node 18+ (uses child_process + streams; no global fetch needed). No framework.
// Sits behind your existing reverse proxy on HTTPS:443. The watch calls
//   GET /transcode?item=li_x&file=<ino>&fmt=mp3&start=<s>&end=<s>&key=<SIDECAR_KEY>
// and gets back a single, complete audio body (mp3 by default) it stores.
//
// Why this exists: (1) ABS will NOT transcode to plain MP3 for us and Garmin
// cannot consume ABS's HLS/AAC transcode output; (2) ABS serves whole files
// only, so per-chapter cuts must happen here. The ABS token stays server-side.
//
// ffmpeg pulls the source straight from ABS over HTTP (NOT via a Node pipe) so
// it can issue Range requests and SEEK. Seeking is required to demux .m4b/.mp4
// (whose moov index is usually at end-of-file) and to cut a chapter without
// reading the whole book. mp3/flac/opus stream fine this way too.
// (Note: the ABS token is passed to ffmpeg via -headers, so it is visible in
// this host's process list. That's acceptable for a localhost-only sidecar.)

import http from 'node:http';
import { spawn } from 'node:child_process';
import { pipeline } from 'node:stream/promises';

const ABS         = (process.env.ABS_URL || '').replace(/\/+$/, ''); // e.g. https://abs.example.com
const ABS_TOKEN   = process.env.ABS_TOKEN;    // ABS long-lived API key (download permission)
const SIDECAR_KEY = process.env.SIDECAR_KEY;  // shared secret the watch must send
const PORT        = Number(process.env.PORT || 8081);

if (!ABS || !ABS_TOKEN || !SIDECAR_KEY) {
  console.error('Missing env: ABS_URL, ABS_TOKEN, SIDECAR_KEY are required. See .env.example');
  process.exit(1);
}

// Content-Type must match the watch's declared :mediaEncoding.
const CT = { mp3: 'audio/mpeg', m4a: 'audio/aac' };

// Build ffmpeg args. Input options (auth header, reconnect, input-side seek)
// MUST precede -i. Input-side -ss is fast (Range-based) and accurate enough for
// spoken word. mp3 (default) transcodes; m4a copies AAC to ADTS (no re-encode).
function ffArgs(srcUrl, fmt, start, end) {
  const args = ['-hide_banner', '-loglevel', 'error',
    '-headers', `Authorization: Bearer ${ABS_TOKEN}\r\n`,
    '-reconnect', '1', '-reconnect_streamed', '1', '-reconnect_delay_max', '2'];
  if (start != null) { args.push('-ss', String(start)); }         // seek before decoding
  args.push('-i', srcUrl);
  if (start != null && end != null) { args.push('-t', String(Math.max(0, Number(end) - Number(start)))); }
  else if (end != null)            { args.push('-to', String(end)); }

  if (fmt === 'm4a') {
    // Lossless AAC -> ADTS.
    args.push('-map', '0:a:0', '-c:a', 'copy', '-f', 'adts', 'pipe:1');
  } else {
    // Transcode to 64k mono MP3 (spoken-word sweet spot, ~28 MB/hour).
    args.push('-map', '0:a:0', '-c:a', 'libmp3lame', '-b:a', '64k', '-ac', '1', '-ar', '22050', '-f', 'mp3', 'pipe:1');
  }
  return args;
}

const server = http.createServer(async (req, res) => {
  const u = new URL(req.url, 'http://x');
  if (u.pathname !== '/transcode') { res.writeHead(404).end(); return; }
  if (u.searchParams.get('key') !== SIDECAR_KEY) { res.writeHead(401).end(); return; }

  const item  = u.searchParams.get('item');
  const file  = u.searchParams.get('file');
  const fmt   = (u.searchParams.get('fmt') || 'mp3').toLowerCase();
  const start = u.searchParams.get('start');
  const end   = u.searchParams.get('end');

  // Validate + whitelist to avoid SSRF/path abuse. item/file feed the ABS URL;
  // start/end feed ffmpeg -ss/-t, so keep them numeric.
  if (!item || !file || !CT[fmt] || !/^[A-Za-z0-9_\-]+$/.test(item) || !/^[0-9]+$/.test(file)) {
    res.writeHead(400).end('bad params'); return;
  }
  if ((start != null && !/^[0-9]+$/.test(start)) || (end != null && !/^[0-9]+$/.test(end))) {
    res.writeHead(400).end('bad range'); return;
  }

  // ffmpeg fetches from ABS itself (server-side auth) and seeks via Range.
  const srcUrl = `${ABS}/api/items/${encodeURIComponent(item)}/file/${encodeURIComponent(file)}/download`;
  const ff = spawn('ffmpeg', ffArgs(srcUrl, fmt, start, end), { stdio: ['ignore', 'pipe', 'inherit'] });

  res.writeHead(200, { 'Content-Type': CT[fmt], 'Cache-Control': 'no-store' });
  ff.on('error', () => { if (!res.writableEnded) res.destroy(); });
  req.on('close', () => { ff.kill('SIGKILL'); }); // watch aborted the download -> stop ffmpeg

  try {
    await pipeline(ff.stdout, res);
  } catch (e) {
    ff.kill('SIGKILL');
    if (!res.writableEnded) res.destroy();
  }
});

// Bind localhost only; the reverse proxy is the public surface on :443.
server.listen(PORT, '127.0.0.1', () => {
  console.log(`WatchShelf sidecar on http://127.0.0.1:${PORT} -> ${ABS}`);
});
