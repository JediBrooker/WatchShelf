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

    // GET /files -> { title, files: [{ino, duration, size, codec}] } (tiny).
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
    // flushed much later. `cb` receives (code, data): the live playback path
    // passes a mark-clean listener; the sync flush passes its own step callback.
    function postProgress(itemId, currentTimeSec, durationSec, lastUpdateSec, cb) {
        var params = { "itemId" => itemId, "currentTime" => currentTimeSec };
        if (durationSec != null) { params["duration"] = durationSec; }
        if (lastUpdateSec != null) { params["lastUpdateSec"] = lastUpdateSec; }
        Communications.makeWebRequest(
            sidecarBase() + "/progress?token=" + authToken(),
            params,
            { :method => Communications.HTTP_REQUEST_METHOD_POST,
              :headers => { "Content-Type" => Communications.REQUEST_CONTENT_TYPE_JSON },
              :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON },
            cb);
    }

    // Live playback push: fire, and clear the book's dirty flag on a confirmed
    // 200 (so an online listen never needs a later flush; an offline one stays
    // dirty and gets flushed on the next sync).
    function patchProgress(itemId, currentTimeSec, durationSec, lastUpdateSec) {
        postProgress(itemId, currentTimeSec, durationSec, lastUpdateSec,
            new AbsProgressListener(itemId, lastUpdateSec).method(:onResponse));
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

    // Parse a getProgress() response into [positionSec, lastUpdateSec], or null
    // when the book has no server progress (empty {} or missing fields).
    function readProgress(data) {
        if ((data == null) || (data["currentTime"] == null) || (data["lastUpdate"] == null)) {
            return null;
        }
        return [data["currentTime"], data["lastUpdate"]];
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
    function _noSlash(url) {
        if ((url != null) && url.length() > 0 && url.substring(url.length() - 1, url.length()).equals("/")) {
            return url.substring(0, url.length() - 1);
        }
        return url;
    }
}

// Owns the live-playback progress-update callback. AbsApi is a module (no
// `self`), so `method(:...)` cannot resolve inside it; a class instance can. The
// instance stays alive while the request is in flight because makeWebRequest
// holds a reference to the Method it is given. On a confirmed 200 it clears the
// book's dirty flag (markClean guards against clobbering a newer in-flight
// write); a failure leaves it dirty for the next sync's flush.
class AbsProgressListener {
    private var mItemId;
    private var mTsSec;
    function initialize(itemId, tsSec) {
        mItemId = itemId;
        mTsSec = tsSec;
    }
    function onResponse(code, data) {
        if (code == 200) {
            Progress.markClean(mItemId, mTsSec);
        } else {
            System.println("ABS progress update failed: " + code);
        }
    }
}
