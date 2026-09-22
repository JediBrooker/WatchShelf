// Podcast support: the sidecar disguises a podcast library as a book library so
// the watch app needs no changes (see the "Podcast support" block in
// server.js). These tests drive the REAL server against a mock Audiobookshelf,
// so every assertion goes through the actual routing, id-splitting and
// response-shaping code.
//
//   node --test sidecar/test/podcast.test.js
//
// The mock records the ABS paths the sidecar calls, which is how the
// per-episode progress assertions prove it hit the episode endpoint rather than
// the item one.

import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const SERVER = join(HERE, '..', 'server.js');

const BOOK_LIB = 'aaaaaaaa-0000-4000-8000-000000000001';
const POD_LIB  = 'bbbbbbbb-0000-4000-8000-000000000002';
const SHOW     = 'cccccccc-0000-4000-8000-000000000003';
const EP_OLD   = 'dddddddd-0000-4000-8000-000000000004';
const EP_NEW   = 'eeeeeeee-0000-4000-8000-000000000005';
const BOOK     = 'ffffffff-0000-4000-8000-000000000006';

// A JWT the sidecar can read an `exp` out of, far enough ahead that
// freshAccess() never tries to refresh mid-test.
const jwt = () => {
  const payload = Buffer.from(JSON.stringify({ exp: Math.floor(Date.now() / 1000) + 3600 }))
    .toString('base64url');
  return `h.${payload}.s`;
};

let abs, absPort, side, sidePort, sid;
const absCalls = [];

function mockAbs() {
  return http.createServer((req, res) => {
    const u = new URL(req.url, 'http://x');
    absCalls.push(`${req.method} ${u.pathname}`);
    const send = (o, code = 200) => {
      res.writeHead(code, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(o));
    };
    const p = u.pathname;

    if (p === '/login') {
      return send({ user: { accessToken: jwt(), refreshToken: 'refresh', username: 'tester' } });
    }
    if (p === '/api/libraries') {
      return send({ libraries: [
        { id: BOOK_LIB, name: 'Books', mediaType: 'book' },
        { id: POD_LIB,  name: 'Shows', mediaType: 'podcast' },
      ] });
    }
    if (p === `/api/libraries/${POD_LIB}`)  { return send({ library: { id: POD_LIB, mediaType: 'podcast' } }); }
    if (p === `/api/libraries/${BOOK_LIB}`) { return send({ library: { id: BOOK_LIB, mediaType: 'book' } }); }

    // Shows in the podcast library -> offered to the watch as "authors".
    if (p === `/api/libraries/${POD_LIB}/items`) {
      return send({ results: [
        { id: SHOW, media: { metadata: { title: 'My Show' }, numEpisodes: 2 } },
      ] });
    }
    if (p === `/api/libraries/${POD_LIB}/recent-episodes`) {
      return send({ episodes: [
        { id: EP_NEW, libraryItemId: SHOW, title: 'Newer', publishedAt: 300, podcast: { metadata: { title: 'My Show' } } },
        { id: EP_OLD, libraryItemId: SHOW, title: 'Older', publishedAt: 100, podcast: { metadata: { title: 'My Show' } } },
      ] });
    }
    // Book library listing, for the regression check.
    if (p === `/api/libraries/${BOOK_LIB}/items`) {
      return send({ results: [
        { id: BOOK, media: { metadata: { title: 'A Book', authorName: 'An Author' }, duration: 3600 } },
      ] });
    }

    // Show detail: episodes deliberately returned OLDEST-first so the
    // newest-first ordering has to come from the sidecar, not the fixture.
    if (p === `/api/items/${SHOW}`) {
      return send({ id: SHOW, media: {
        metadata: { title: 'My Show' },
        episodes: [
          { id: EP_OLD, title: 'Older', publishedAt: 100, audioFile: { ino: '101', duration: 61 } },
          { id: EP_NEW, title: 'Newer', publishedAt: 300, audioFile: { ino: '202', duration: 62 } },
        ],
      } });
    }
    if (p === `/api/items/${BOOK}`) {
      return send({ id: BOOK, media: {
        metadata: { title: 'A Book', authorName: 'An Author' },
        audioFiles: [{ ino: '900', duration: 3600 }],
      }, userMediaProgress: { currentTime: 5, duration: 3600, lastUpdate: 1700000000000, isFinished: false } });
    }

    // The direct per-episode progress row. 404 = nothing recorded yet.
    if (p === `/api/me/progress/${SHOW}/${EP_OLD}`) {
      return send({ libraryItemId: SHOW, episodeId: EP_OLD, currentTime: 12, duration: 61,
                    lastUpdate: 1700000000000, isFinished: false });
    }
    if (p.startsWith('/api/me/progress/') && req.method === 'GET') { res.writeHead(404).end(); return; }

    // /api/me is deliberately NOT served: pulling the user's whole
    // mediaProgress array on every episode open is what the direct endpoint
    // replaced, so a regression to it must fail loudly here.
    if (p === '/api/me') { res.writeHead(500).end('should not be called'); return; }
    if (p === '/api/me/items-in-progress') {
      return send({ libraryItems: [
        { id: SHOW, libraryId: POD_LIB, mediaType: 'podcast',
          media: { metadata: { title: 'My Show' } },
          recentEpisode: { id: EP_NEW, title: 'Newer', publishedAt: 300 } },
        { id: BOOK, libraryId: BOOK_LIB, mediaType: 'book',
          media: { metadata: { title: 'A Book', authorName: 'An Author' }, duration: 3600 } },
      ] });
    }
    if (p.startsWith('/api/me/progress/')) { return send({ ok: true }); }   // PATCH

    res.writeHead(404).end();
  });
}

const listen = (srv) => new Promise((r) => srv.listen(0, '127.0.0.1', () => r(srv.address().port)));

async function get(path) {
  const r = await fetch(`http://127.0.0.1:${sidePort}${path}`);
  const text = await r.text();
  try { return { status: r.status, body: JSON.parse(text) }; }
  catch { return { status: r.status, body: text }; }
}

before(async () => {
  abs = mockAbs();
  absPort = await listen(abs);

  // BASE_PATH='' so the tests address routes directly.
  const probe = http.createServer(); sidePort = await listen(probe);
  await new Promise((r) => probe.close(r));

  side = spawn(process.execPath, [SERVER], {
    env: { ...process.env, ABS_URL: `http://127.0.0.1:${absPort}`, PORT: String(sidePort),
           BIND: '127.0.0.1', BASE_PATH: '', SESSIONS_FILE: '' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  // Wait for /health rather than sleeping.
  for (let i = 0; i < 100; i++) {
    try {
      const r = await fetch(`http://127.0.0.1:${sidePort}/health`);
      if (r.ok && (await r.text()) === 'ok') { break; }
    } catch { /* not up yet */ }
    await new Promise((r) => setTimeout(r, 50));
  }

  const r = await fetch(`http://127.0.0.1:${sidePort}/login`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: 'tester', password: 'pw' }),
  });
  sid = (await r.json()).user.token;
  assert.ok(sid, 'login must yield a session id');
});

after(() => { side?.kill(); abs?.close(); });

test('a podcast library is reported to the watch as a book library', async () => {
  const { body } = await get(`/libraries?token=${sid}`);
  const shows = body.libraries.find((l) => l.id === POD_LIB);
  // LibraryView.mc only lists libraries whose mediaType equals "book", so the
  // disguise is what makes podcasts reachable at all without a watch change.
  assert.equal(shows.mediaType, 'book');
  assert.equal(shows.name, 'Shows');
});

test('shows are offered as authors to drill into', async () => {
  const { body } = await get(`/authors?lib=${POD_LIB}&token=${sid}`);
  assert.deepEqual(body.authors, [{ id: SHOW, name: 'My Show', count: 2 }]);
});

test('podcasts have no series or collections', async () => {
  assert.deepEqual((await get(`/series?lib=${POD_LIB}&token=${sid}`)).body, { series: [] });
  assert.deepEqual((await get(`/collections?lib=${POD_LIB}&token=${sid}`)).body, { collections: [] });
});

test('a show lists its episodes as books, newest first', async () => {
  const { body } = await get(`/list?lib=${POD_LIB}&author=${SHOW}&token=${sid}`);
  assert.deepEqual(body.books.map((b) => b.title), ['Newer', 'Older']);
  // The composite id is what lets every later route recover both halves.
  assert.equal(body.books[0].id, `${SHOW}__${EP_NEW}`);
  assert.equal(body.books[0].author, 'My Show');
});

test('/files turns one episode into a one-file book with its progress', async () => {
  const { body } = await get(`/files?item=${SHOW}__${EP_OLD}&token=${sid}`);
  assert.equal(body.title, 'Older');
  assert.equal(body.author, 'My Show');
  assert.deepEqual(body.files, [{ ino: '101', duration: 61 }]);
  // Episode progress comes from the user's mediaProgress rows, not item detail.
  assert.equal(body.progress.currentTime, 12);
  // Proves the one-row endpoint was used, not a scan of /api/me.
  assert.ok(absCalls.includes(`GET /api/me/progress/${SHOW}/${EP_OLD}`));
  assert.ok(!absCalls.includes('GET /api/me'), 'must not pull the whole progress array');
});

test('/files 404s for an episode that is not in the show', async () => {
  const { status } = await get(`/files?item=${SHOW}__${BOOK}&token=${sid}`);
  assert.equal(status, 404);
});

test('reading progress for an episode uses the episode row', async () => {
  const { body } = await get(`/progress?item=${SHOW}__${EP_OLD}&token=${sid}`);
  assert.equal(body.currentTime, 12);
  // An episode with no row yet must read as "no progress", not as the show's.
  assert.deepEqual((await get(`/progress?item=${SHOW}__${EP_NEW}&token=${sid}`)).body, {});
});

test('writing progress PATCHes ABS per-episode, not per-item', async () => {
  absCalls.length = 0;
  const r = await fetch(`http://127.0.0.1:${sidePort}/progress?token=${sid}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ itemId: `${SHOW}__${EP_OLD}`, currentTime: 30, duration: 61, lastUpdateSec: 1700000001 }),
  });
  assert.equal(r.status, 200);
  assert.ok(absCalls.includes(`PATCH /api/me/progress/${SHOW}/${EP_OLD}`),
    `expected a per-episode PATCH, saw: ${absCalls.join(', ')}`);
});

test('continue listening shims a podcast item to its in-progress episode', async () => {
  const { body } = await get(`/continue?lib=${POD_LIB}&token=${sid}`);
  assert.deepEqual(body.books, [{ id: `${SHOW}__${EP_NEW}`, title: 'Newer', author: 'My Show' }]);
});

test('book libraries are unaffected', async () => {
  const libs = (await get(`/libraries?token=${sid}`)).body.libraries;
  assert.equal(libs.find((l) => l.id === BOOK_LIB).mediaType, 'book');

  const { body: list } = await get(`/list?lib=${BOOK_LIB}&token=${sid}`);
  assert.deepEqual(list.books, [{ id: BOOK, title: 'A Book', author: 'An Author' }]);

  const { body: files } = await get(`/files?item=${BOOK}&token=${sid}`);
  assert.deepEqual(files.files, [{ ino: '900', duration: 3600 }]);
  assert.equal(files.progress.currentTime, 5);

  const { body: cont } = await get(`/continue?lib=${BOOK_LIB}&token=${sid}`);
  assert.deepEqual(cont.books, [{ id: BOOK, title: 'A Book', author: 'An Author' }]);
});
