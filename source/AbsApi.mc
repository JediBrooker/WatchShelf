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
            { :method => Communications.HTTP_REQUEST_METHOD_GET,
              :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON },
            cb);
    }

    // GET /continue -> { books: [{id, title, author}] }, limited to books in
    // this library that the current ABS user has started but not finished.
    function getContinueList(libId, cb) {
        Communications.makeWebRequest(
            sidecarBase() + "/continue",
            { "lib" => libId, "token" => authToken() },
            { :method => Communications.HTTP_REQUEST_METHOD_GET,
              :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON },
            cb);
    }

    // Lean group lists for browse-by: /authors, /series, /collections.
    function getGroups(path, libId, cb) {
        Communications.makeWebRequest(
            sidecarBase() + path,
            { "lib" => libId, "token" => authToken() },
            { :method => Communications.HTTP_REQUEST_METHOD_GET,
              :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON },
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
            { :method => Communications.HTTP_REQUEST_METHOD_GET,
              :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON },
            cb);
    }

    // One CHUNK of a file as a small AAC chunk in a REAL M4A container (the
    // container is what gives the native player a track duration - see
    // SyncDelegate). fmt=m4a2 doubles as the watch/sidecar protocol-version
    // guard: an older sidecar doesn't know it and 400s, so the sync fails
    // VISIBLY instead of the old sidecar's raw ADTS being silently cached
    // under ENCODING_M4A (which would poison every downloaded chunk).
    function sidecarChunkUrl(itemId, ino, startSec, endSec) {
        return sidecarBase() + "/transcode?item=" + itemId + "&file=" + ino
            + "&fmt=m4a2&start=" + startSec.toString() + "&end=" + endSec.toString()
            + "&token=" + authToken();
    }

    // Cover image URL for Communications.makeImageRequest. Image requests
    // cannot send custom headers (no :headers option exists on them), so auth
    // rides in the URL like every other watch-facing sidecar route. `px`
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
            { :method => Communications.HTTP_REQUEST_METHOD_GET,
              :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON },
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
            { :method => Communications.HTTP_REQUEST_METHOD_POST,
              :headers => { "Content-Type" => Communications.REQUEST_CONTENT_TYPE_JSON },
              :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON },
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
            { :method => Communications.HTTP_REQUEST_METHOD_GET,
              :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON },
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
            _noSlash(server) + "/health", null,
            { :method => Communications.HTTP_REQUEST_METHOD_GET,
              :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_TEXT_PLAIN },
            cb);
    }

    function login(server, username, password, cb) {
        Communications.makeWebRequest(
            _noSlash(server) + "/login",
            { "username" => username, "password" => password },
            { :method => Communications.HTTP_REQUEST_METHOD_POST,
              :headers => { "Content-Type" => Communications.REQUEST_CONTENT_TYPE_JSON },
              :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON },
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
    private var mQueue;
    private var mBusy;
    private var mCurId;
    private var mCurTs;
    private var mCurPos;
    private var mCurFinished;

    function initialize() {
        mQueue = [];
        mBusy = false;
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
            AbsApi.getProgress(mCurId, method(:onPullDone));
            return;
        }
    }

    function onPullDone(code, data) {
        if (code == 200) {
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
        mCurPos = e[0];
        mCurTs = e[1];
        mCurFinished = Progress.entryFinished(e);
        AbsApi.postProgress(mCurId, mCurPos, duration(mCurId), mCurTs,
            mCurFinished ? true : null, method(:onResponse));
    }

    function onResponse(code, data) {
        if (code == 200) {
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
