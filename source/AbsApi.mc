using Toybox.Application;
using Toybox.Communications;
using Toybox.Lang;
using Toybox.Media;
using Toybox.System;

// WatchShelf HTTP client. The watch talks ONLY to the sidecar: the server URL the
// user logs in with IS the sidecar's public URL (any HTTPS endpoint - a subdomain
// or a path). The sidecar proxies login + libraries to Audiobookshelf (which can
// stay fully internal) and serves lean lists + on-demand audio chunks. Auth is the
// ABS token obtained at login, passed as ?token=.
module AbsApi {

    // ---- config accessors (never crash if a setting is unset) --------------
    // Config comes from EITHER on-watch login (Application.Storage - works for a
    // sideloaded app) OR phone/Garmin-Connect settings (Application.Properties -
    // only available once the app is published to the Connect IQ Store). The
    // login values (Storage) win when present.
    function serverUrl() {
        var v = Application.Storage.getValue(Store.SERVER);
        if (v == null) { v = _prop(Settings.SERVER_URL); }
        if (v == null) { return null; }
        if (v.length() > 0 && v.substring(v.length() - 1, v.length()).equals("/")) {
            v = v.substring(0, v.length() - 1);
        }
        return v;
    }
    // Bearer token: the on-watch login token (Storage), else an API key (settings).
    function authToken() {
        var v = Application.Storage.getValue(Store.TOKEN);
        if (v == null) { v = _prop(Settings.API_KEY); }
        return v;
    }

    // ---- optional reverse-proxy header (issue #41) -------------------------
    // Users who expose the sidecar to the internet may want to gate it at a
    // reverse proxy: set a header here and have Caddy/nginx/Traefik drop any
    // request that lacks it. Both halves must be present or nothing is sent -
    // a name with no secret would just advertise the scheme.
    function proxyName()  { return _cfg(Store.PROXY_NAME, Settings.PROXY_NAME); }
    function proxyValue() { return _cfg(Store.PROXY_VALUE, Settings.PROXY_VALUE); }
    function hasProxyHeader() {
        return (proxyName() != null) && (proxyValue() != null);
    }

    // { name => secret } for the request options, or null when unconfigured.
    function proxyHeaders() {
        if (!hasProxyHeader()) { return null; }
        return { proxyName() => proxyValue() };
    }

    // GET/POST option builders. Every watch->sidecar call goes through these so
    // the proxy header cannot be forgotten on a new route - the failure mode
    // otherwise is a single unguarded request that the proxy rejects, which
    // looks like an unrelated intermittent fault. :headers is OMITTED entirely
    // rather than passed as null/{} when there is no header to send, keeping
    // the request byte-identical to before this feature for everyone else.
    function getOptions() {
        var o = { :method => Communications.HTTP_REQUEST_METHOD_GET,
                  :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON };
        var h = proxyHeaders();
        if (h != null) { o[:headers] = h; }
        return o;
    }

    function postOptions() {
        var headers = { "Content-Type" => Communications.REQUEST_CONTENT_TYPE_JSON };
        if (hasProxyHeader()) { headers[proxyName()] = proxyValue(); }
        return { :method => Communications.HTTP_REQUEST_METHOD_POST,
                 :headers => headers,
                 :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON };
    }

    // Storage (entered on the watch) wins over Properties (phone settings),
    // matching serverUrl()/authToken(). Empty strings count as unset.
    function _cfg(storeKey, settingKey) {
        var v = Application.Storage.getValue(storeKey);
        if ((v != null) && (v instanceof Lang.String) && (v.length() == 0)) { v = null; }
        if (v == null) { v = _prop(settingKey); }
        return v;
    }
    // ---- sidecar (server.js behind {server}/watchshelf-transcode) ----------
    // ALL heavy operations route through the sidecar: most books here are single
    // 200MB-1GB files the watch cannot download whole, so the sidecar serves lean
    // lists and cuts small on-demand chunks. Auth is the watch's own ABS token.
    // The server URL the user logged in with IS the sidecar base (they enter the
    // sidecar's full public URL - subdomain or same-domain path - directly).
    function sidecarBase() { return serverUrl(); }

    // GET /list -> { books: [{id, title, author}] }. filterType is
    // "author"/"series"/"collection" (with filterId), or null for all books.
    function getBookList(libId, filterType, filterId, cb) {
        var params = { "lib" => libId, "token" => authToken() };
        if (filterType != null && filterId != null) { params[filterType] = filterId; }
        Communications.makeWebRequest(
            sidecarBase() + "/list", params,
            getOptions(),
            cb);
    }

    // GET /continue -> { books: [{id, title, author}] }, limited to books in
    // this library that the current ABS user has started but not finished.
    function getContinueList(libId, cb) {
        Communications.makeWebRequest(
            sidecarBase() + "/continue",
            { "lib" => libId, "token" => authToken() },
            getOptions(),
            cb);
    }

    // Lean group lists for browse-by: /authors, /series, /collections.
    function getGroups(path, libId, cb) {
        Communications.makeWebRequest(
            sidecarBase() + path,
            { "lib" => libId, "token" => authToken() },
            getOptions(),
            cb);
    }
    function getAuthors(libId, cb)     { getGroups("/authors", libId, cb); }
    function getSeries(libId, cb)      { getGroups("/series", libId, cb); }
    function getCollections(libId, cb) { getGroups("/collections", libId, cb); }

    // GET /files -> { title, author, files:[{ino,duration}], progress } (tiny).
    // progress is the slim server resume state, or null when never started.
    function getFiles(itemId, cb) {
        Communications.makeWebRequest(
            sidecarBase() + "/files",
            { "item" => itemId, "token" => authToken() },
            getOptions(),
            cb);
    }

    // One CHUNK of a file as a small AAC chunk in a REAL M4A container (the
    // container is what gives the native player a track duration - see
    // SyncDelegate). fmt=m4a3 requires speed-aware sidecar support; an older
    // sidecar returns 400 instead of silently serving incompatible audio.
    function sidecarChunkUrl(itemId, ino, startSec, endSec, speed) {
        return sidecarBase() + "/transcode?item=" + itemId + "&file=" + ino
            + "&fmt=m4a3&start=" + startSec.toString() + "&end=" + endSec.toString()
            + "&speed=" + PlaybackSpeed.normalize(speed).toString()
            + "&token=" + authToken();
    }

    // Cover image URL for Communications.makeImageRequest. Image requests
    // cannot send custom headers (no :headers option exists on them), so auth
    // rides in the URL like every other watch-facing sidecar route.
    // CAUTION: that also means an image request CANNOT carry the optional
    // reverse-proxy header, so it would be rejected by a proxy configured per
    // issue #41. Nothing calls this today (cover fetching was removed from the
    // sync path in b35), but anything that revives it must either pass the
    // secret some other way or accept that covers break behind a proxy. `px`
    // bounds what ABS ships over the wire; Garmin Connect Mobile then scales/
    // dithers to the device's actual capability.
    function coverUrl(itemId, px) {
        return sidecarBase() + "/cover?item=" + itemId + "&w=" + px.toString()
            + "&token=" + authToken();
    }

    function _prop(key) {
        // Properties.getValue throws if the key is undeclared; ours are declared
        // in properties.xml so this is safe, but guard for empty strings.
        var v = Application.Properties.getValue(key);
        if ((v != null) && (v instanceof Lang.String) && (v.length() == 0)) { return null; }
        return v;
    }

    function isConfigured() {
        return (serverUrl() != null) && (authToken() != null);
    }

    // ---- library / item listing -------------------------------------------

    // GET /libraries -> callback(code, data). data.libraries[] each {id,name}.
    function getLibraries(callback) {
        Communications.makeWebRequest(
            sidecarBase() + "/libraries",
            { "token" => authToken() },
            getOptions(),
            callback);
    }

    // ---- progress sync (two-way) -------------------------------------------

    // WRITE: push a position to ABS via the sidecar (Monkey C has no PATCH; ABS
    // ignores X-HTTP-Method-Override, so the watch POSTs and the sidecar PATCHes
    // with the same token). `lastUpdateSec` is the watch's listen time in epoch
    // SECONDS; the sidecar converts it to ABS's millisecond lastUpdate so
    // cross-device last-write-wins orders correctly - even for an offline listen
    // flushed much later. `cb` receives (code, data): the serialized live
    // dispatcher and the sync flush each pass their own step callback.
    function postProgress(itemId, currentTimeSec, durationSec, lastUpdateSec, isFinished, cb) {
        var params = { "itemId" => itemId, "currentTime" => currentTimeSec };
        if (durationSec != null) { params["duration"] = durationSec; }
        if (lastUpdateSec != null) { params["lastUpdateSec"] = lastUpdateSec; }
        // Only authoritative final-part COMPLETE carries this field. A normal
        // position change below ABS's completion threshold automatically
        // reopens a completed book. Sending explicit false is unsafe on current
        // ABS: its unfinish branch resets currentTime to zero and discards the
        // position supplied in that same PATCH.
        if (isFinished == true) { params["isFinished"] = true; }
        Communications.makeWebRequest(
            sidecarBase() + "/progress?token=" + authToken(),
            params,
            postOptions(),
            cb);
    }

    // READ: GET the saved position for one book from the sidecar (which reads
    // ABS item detail with ?include=progress). Response is the slim shape
    // { currentTime, duration, lastUpdate, isFinished } in SECONDS, or {} when
    // ABS has no progress for this item. `cb` receives (code, data).
    function getProgress(itemId, cb) {
        Communications.makeWebRequest(
            sidecarBase() + "/progress",
            { "item" => itemId, "token" => authToken() },
            getOptions(),
            cb);
    }

    // Parse a getProgress() response into
    // [positionSec, lastUpdateSec, isFinished], or null
    // when the book has no server progress (empty {} or missing fields).
    function readProgress(data) {
        if ((data == null) || (data["currentTime"] == null) || (data["lastUpdate"] == null)) {
            return null;
        }
        return [data["currentTime"], data["lastUpdate"], data["isFinished"] == true];
    }

    // ---- on-watch login ----------------------------------------------------

    // Preflight: is this URL actually a WatchShelf sidecar? Its /health
    // returns exactly "ok" (text/plain). Logging into the ABS server's own
    // URL by mistake is otherwise indistinguishable at login time - ABS has
    // its OWN /login that succeeds and returns a token, and every call after
    // that gets an HTML page the watch reports as an opaque -400. Verified
    // end-to-end in the simulator: correct sidecar URL -> library loads;
    // ABS URL -> caught here before credentials are sent.
    function checkHealth(server, cb) {
        Communications.makeWebRequest(
            _noSlash(server) + "/health", null, healthOptions(), cb);
    }

    // /health is text/plain, not JSON, so it needs its own options - but it is
    // also the FIRST request of a login and therefore the first thing a proxy
    // sees. It must carry the header or login preflight fails before the user
    // has any way to discover why.
    function healthOptions() {
        var o = { :method => Communications.HTTP_REQUEST_METHOD_GET,
                  :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_TEXT_PLAIN };
        var h = proxyHeaders();
        if (h != null) { o[:headers] = h; }
        return o;
    }

    function login(server, username, password, cb) {
        Communications.makeWebRequest(
            _noSlash(server) + "/login",
            { "username" => username, "password" => password },
            postOptions(),
            cb);
    }
    function saveLogin(server, token) {
        Application.Storage.setValue(Store.SERVER, _noSlash(server));
        Application.Storage.setValue(Store.TOKEN, token);
    }
    function logout() {
        Application.Storage.deleteValue(Store.SERVER);
        Application.Storage.deleteValue(Store.TOKEN);
    }
    // Drop ONLY the login token, keeping the server URL. Used when ABS reports
    // the session is dead (401): isConfigured() flips false so the login flow
    // restarts, but the user doesn't have to re-type their server URL.
    function clearToken() {
        Application.Storage.deleteValue(Store.TOKEN);
    }
    function _noSlash(url) {
        if ((url != null) && url.length() > 0 && url.substring(url.length() - 1, url.length()).equals("/")) {
            return url.substring(0, url.length() - 1);
        }
        return url;
    }
}

// One app-wide live progress dispatcher. Playback callbacks can arrive faster
// than HTTP responses (especially NOTIFY immediately followed by final
// COMPLETE), and ABS applies PATCHes in arrival order rather than comparing
// lastUpdate. Sending one at a time prevents an older ordinary position from
// landing after isFinished:true and reopening the book. Every callback first
// persists its latest state in Progress; the queue therefore coalesces repeated
// events for a book without losing the newest position. It also spans delegate
// replacement, so stop/start on the same book cannot race two HTTP writes.
module LiveProgress {
    var worker = null;

    function submit(itemId) {
        if (worker == null) { worker = new LiveProgressWorker(); }
        worker.submit(itemId);
    }
}

class LiveProgressWorker {
    // Seconds before the watch re-checks the server for a book it has already
    // exchanged with in this session. See needsPull().
    const PULL_TTL = 300;

    private var mQueue;
    private var mBusy;
    private var mCurId;
    private var mCurTs;
    private var mCurPos;
    private var mCurFinished;
    private var mChecked;   // itemId -> epoch sec of last confirmed exchange

    function initialize() {
        mQueue = [];
        mBusy = false;
        mChecked = {};
    }

    // Record that we have fresh knowledge of the server's state for a book -
    // either we just pulled it, or we just pushed to it successfully.
    function noteChecked(itemId, tsSec) {
        mChecked[itemId] = tsSec;
    }

    // Should this push be preceded by a server pull?
    //
    // The pull exists to stop a STALE resume position clobbering a newer
    // position set on another device. That can only happen on the FIRST
    // exchange for a book, before the watch has established itself as the most
    // recent writer. Afterwards every position in the same listening session is
    // strictly newer AND from this same device, so a pull costs a round trip
    // and learns nothing.
    //
    // That distinction matters because live events are NOT occasional:
    // PLAYBACK_NOTIFY fires every ~15s of playback (see
    // ContentIterator.playbackNotificationThreshold), so an hour of listening is
    // ~240 pushes. Pulling before every one would make it ~480 requests over the
    // phone bridge. With the TTL it is ~12 pulls an hour and the pull that
    // actually protects anything - the first - still happens.
    //
    // The TTL covers the other direction: a long pause during which another
    // device moved on. After PULL_TTL the watch stops assuming it is still the
    // most recent writer.
    function needsPull(itemId, nowSec) {
        var last = mChecked[itemId];
        if (last == null) { return true; }
        // A clock that jumped BACKWARD (manual set, or a firmware time
        // correction) must not pin this false until the TTL elapses in the new
        // frame - re-check instead of trusting arithmetic on a moved clock.
        if (nowSec < last) { return true; }
        return (nowSec - last) >= PULL_TTL;
    }

    function submit(itemId) {
        if (!isQueued(itemId)) { mQueue.add(itemId); }
        drain();
    }

    function isQueued(itemId) {
        for (var i = 0; i < mQueue.size(); ++i) {
            if (mQueue[i].equals(itemId)) { return true; }
        }
        return false;
    }

    function shiftQueue() {
        var itemId = mQueue[0];
        var rest = [];
        for (var i = 1; i < mQueue.size(); ++i) { rest.add(mQueue[i]); }
        mQueue = rest;
        return itemId;
    }

    function duration(itemId) {
        var meta = BookStore.get(itemId);
        if ((meta == null) || (meta["durs"] == null)) { return null; }
        var total = 0;
        var durs = meta["durs"];
        for (var i = 0; i < durs.size(); ++i) { total += durs[i]; }
        return (total > 0) ? total : null;
    }

    function drain() {
        if (mBusy) { return; }
        while (mQueue.size() > 0) {
            mCurId = shiftQueue();
            var e = Progress.get(mCurId);
            if ((e == null) || !e[2]) { continue; }
            mBusy = true;
            // Pull-before-push, same as ProgressSync: a live position event is
            // stamped with the watch's OWN clock, which is always "now" - so a
            // blind post here would beat a slightly-earlier-but-further-along
            // write from another device on every single resume, not just a
            // genuine race. Merge against the server's current value first and
            // only push if this book is still dirty afterward (i.e. the local
            // write is a real, further-along position - not a stale resume).
            // Throttled - see needsPull().
            if (needsPull(mCurId, Progress.nowSec())) {
                AbsApi.getProgress(mCurId, method(:onPullDone));
            } else {
                pushCurrent();
            }
            return;
        }
    }

    function onPullDone(code, data) {
        if (code == 200) {
            // Only a SUCCESSFUL pull counts as fresh knowledge; a failed one
            // must not suppress the next attempt for a whole TTL.
            noteChecked(mCurId, Progress.nowSec());
            var pr = AbsApi.readProgress(data); // [posSec, tsSec, finished] or null
            if (pr != null) {
                var finished = (pr.size() > 2) ? pr[2] : null;
                Progress.mergeServer(mCurId, pr[0], pr[1], finished);
            }
        }
        var e = Progress.get(mCurId);
        if ((e == null) || !e[2]) {
            // The pull already caught this book up to (or past) the server -
            // nothing left to push.
            mBusy = false;
            drain();
            return;
        }
        pushCurrent();
    }

    // Send the book's current local state. Split out of onPullDone so the
    // throttled path can reach it without a pull.
    function pushCurrent() {
        var e = Progress.get(mCurId);
        if (e == null) { mBusy = false; drain(); return; }
        mCurPos = e[0];
        mCurTs = e[1];
        mCurFinished = Progress.entryFinished(e);
        AbsApi.postProgress(mCurId, mCurPos, duration(mCurId), mCurTs,
            mCurFinished ? true : null, method(:onResponse));
    }

    function onResponse(code, data) {
        if (code == 200) {
            // A successful push makes the watch the most recent writer, which
            // is exactly the state needsPull() may skip a pull for.
            noteChecked(mCurId, Progress.nowSec());
            // Exact-match guard leaves a newer queued callback dirty.
            Progress.markClean(mCurId, mCurTs, mCurPos, mCurFinished);
        } else {
            // Do not spin on a failed request. The persisted dirty state is
            // retried by a later playback event or the next explicit sync.
            System.println("ABS progress update failed: " + code);
        }
        mBusy = false;
        drain();
    }
}
