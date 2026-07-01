using Toybox.Application;
using Toybox.Communications;
using Toybox.Lang;
using Toybox.Media;
using Toybox.System;

// Thin Audiobookshelf HTTP client. All endpoints under {server}/api except
// /login (root). We authenticate every call with a long-lived ABS API key
// (Bearer) taken from Application.Properties, so there is no login/refresh dance.
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
    function sidecarUrl() {
        var v = _prop(Settings.SIDECAR_URL);
        if ((v != null) && v.length() > 0 && v.substring(v.length() - 1, v.length()).equals("/")) {
            v = v.substring(0, v.length() - 1);
        }
        return v;
    }
    function sidecarKey() { return _prop(Settings.SIDECAR_KEY); }
    function hasSidecar() {
        return (sidecarUrl() != null) && (sidecarKey() != null);
    }

    // ---- sidecar (server.js behind {server}/watchshelf-transcode) ----------
    // ALL heavy operations route through the sidecar: most books here are single
    // 200MB-1GB files the watch cannot download whole, so the sidecar serves lean
    // lists and cuts small on-demand chunks. Auth is the watch's own ABS token.
    function sidecarBase() { return serverUrl() + "/watchshelf-transcode"; }

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

    // One CHUNK of a file as a small mp3 the watch can download.
    function sidecarChunkUrl(itemId, ino, startSec, endSec) {
        return sidecarBase() + "/transcode?item=" + itemId + "&file=" + ino
            + "&fmt=mp3&start=" + startSec.toString() + "&end=" + endSec.toString()
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

    // Common auth header for every request.
    function authHeaders() {
        return { "Authorization" => "Bearer " + authToken() };
    }

    // ---- library / item listing -------------------------------------------

    // GET /api/libraries -> callback(code, data). data.libraries[] each {id,name,mediaType}.
    function getLibraries(callback) {
        Communications.makeWebRequest(
            serverUrl() + "/api/libraries",
            null,
            { :method => Communications.HTTP_REQUEST_METHOD_GET,
              :headers => authHeaders(),
              :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON },
            callback);
    }

    // GET /api/libraries/:id/items -> callback(code, data). data.results[] items.
    // minified=1 keeps the payload small; we only need id + title here.
    function getItems(libraryId, callback) {
        Communications.makeWebRequest(
            serverUrl() + "/api/libraries/" + libraryId + "/items",
            // limit is small on purpose: the watch caps makeWebRequest responses
            // (NETWORK_RESPONSE_TOO_LARGE / -402), so we page rather than pull all.
            { "minified" => "1", "limit" => "10", "sort" => "media.metadata.title" },
            { :method => Communications.HTTP_REQUEST_METHOD_GET,
              :headers => authHeaders(),
              :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON },
            callback);
    }

    // GET /api/items/:id?expanded=1&include=progress -> full detail incl.
    // media.audioFiles[], media.chapters[], userMediaProgress.
    function getItemDetail(itemId, callback) {
        Communications.makeWebRequest(
            serverUrl() + "/api/items/" + itemId,
            { "expanded" => "1", "include" => "progress" },
            { :method => Communications.HTTP_REQUEST_METHOD_GET,
              :headers => authHeaders(),
              :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON },
            callback);
    }

    // ---- play session (lean fallback when full item detail is too large) ---
    // POST /api/items/:id/play -> audioTracks[] with contentUrl + mimeType, WITHOUT
    // the per-file metaTags/chapters bloat that overflows the watch on big books.
    function getPlaySession(itemId, cb) {
        Communications.makeWebRequest(
            serverUrl() + "/api/items/" + itemId + "/play",
            { "deviceInfo" => { "clientName" => "WatchShelf" },
              "mediaPlayer" => "WatchShelf",
              "forceDirectPlay" => true,
              "supportedMimeTypes" => ["audio/mpeg", "audio/mp4"] },
            { :method => Communications.HTTP_REQUEST_METHOD_POST,
              :headers => { "Authorization" => "Bearer " + authToken(),
                            "Content-Type" => Communications.REQUEST_CONTENT_TYPE_JSON },
              :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON },
            cb);
    }

    // Build a downloadable URL from a play track's contentUrl (relative path).
    function playTrackUrl(contentUrl) {
        if (contentUrl == null) { return null; }
        var sep = (contentUrl.find("?") != null) ? "&" : "?";
        return serverUrl() + contentUrl + sep + "token=" + authToken();
    }

    // audio/mpeg -> mp3, everything else (audio/mp4, aac) -> m4a. Both direct-play.
    function mimeToType(mime) {
        var m = _lower(mime);
        if ((m != null) && (m.find("mpeg") != null)) { return "mp3"; }
        return "m4a";
    }

    // ---- per-file playback decision (codec-based) --------------------------
    // MP3   -> direct-download from ABS (byte-exact, Garmin plays it; no sidecar).
    // AAC   (aac/m4a/m4b/mp4) -> sidecar copies the AAC stream to ADTS (lossless,
    //        no re-encode) which Garmin plays via ENCODING_ADTS.
    // other (flac/opus/...)   -> sidecar transcodes to mp3.
    function fileIsMp3(audioFile) {
        var codec = _lower(audioFile["codec"]);
        return (codec != null) && codec.equals("mp3");
    }
    function fileIsAac(audioFile) {
        var codec = _lower(audioFile["codec"]);
        return (codec != null) && (codec.equals("aac") || codec.equals("m4a") || codec.equals("mp4a"));
    }

    // Download URL + declared encoding for one whole audio FILE (= one track).
    // MP3 and AAC/m4b BOTH download byte-exact directly from ABS - the watch
    // decodes MP4/AAC, so no sidecar is required for the common library. Only
    // flac/opus need the sidecar transcode.
    function fileTrackUrl(itemId, audioFile) {
        var ino = audioFile["ino"];
        if (fileIsMp3(audioFile) || fileIsAac(audioFile)) { return directFileUrl(itemId, ino); }
        return sidecarFileUrl(itemId, ino, "mp3");
    }
    function fileTrackType(audioFile) {
        if (fileIsMp3(audioFile)) { return "mp3"; }
        if (fileIsAac(audioFile)) { return "m4a"; }
        return "mp3";
    }

    // ---- URL builders ------------------------------------------------------

    // Direct ABS download of a whole audio file (mp3). Token in the query string
    // because makeWebRequest audio downloads are simplest with ?token=.
    // :fileid in the ABS route == the audioFile ino.
    function directFileUrl(itemId, ino) {
        return serverUrl() + "/api/items/" + itemId + "/file/" + ino + "/download?token=" + authToken();
    }

    // Sidecar whole-file convert: fmt=m4a copies AAC -> ADTS; fmt=mp3 transcodes.
    function sidecarFileUrl(itemId, ino, fmt) {
        return sidecarUrl() + "/transcode?item=" + itemId + "&file=" + ino
            + "&fmt=" + fmt + "&key=" + sidecarKey();
    }

    // Sidecar chapter cut: a small complete mp3 for exactly one chapter of a
    // SINGLE-file book, for real chapter navigation. start/end -> integer seconds.
    function sidecarChapterUrl(itemId, ino, startSec, endSec) {
        return sidecarUrl() + "/transcode"
            + "?item=" + itemId
            + "&file=" + ino
            + "&fmt=mp3"
            + "&start=" + startSec.toNumber().toString()
            + "&end=" + endSec.toNumber().toString()
            + "&key=" + sidecarKey();
    }

    // ---- progress sync -----------------------------------------------------

    // Read saved position (seconds) from an item-detail response, or 0.
    function progressSeconds(detail) {
        var p = detail["userMediaProgress"];
        if ((p != null) && (p["currentTime"] != null)) {
            return p["currentTime"];
        }
        return 0;
    }

    // Progress sync via the sidecar (Monkey C has no PATCH; ABS ignores
    // X-HTTP-Method-Override). The watch POSTs; the sidecar PATCHes ABS with the
    // same token. Fire-and-forget.
    function patchProgress(itemId, currentTimeSec, durationSec) {
        var params = { "itemId" => itemId, "currentTime" => currentTimeSec };
        if (durationSec != null) { params["duration"] = durationSec; }
        Communications.makeWebRequest(
            sidecarBase() + "/progress?token=" + authToken(),
            params,
            { :method => Communications.HTTP_REQUEST_METHOD_POST,
              :headers => { "Content-Type" => Communications.REQUEST_CONTENT_TYPE_JSON },
              :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON },
            new AbsProgressListener().method(:onResponse));
    }

    // ---- on-watch login ----------------------------------------------------
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

    // ---- small helpers -----------------------------------------------------
    function _ext(audioFile) {
        var md = audioFile["metadata"];
        if (md != null) { return md["ext"]; }
        return null;
    }
    function _lower(s) {
        if (s == null) { return null; }
        return s.toLower();
    }
}

// Owns the fire-and-forget progress-update callback. AbsApi is a module (no
// `self`), so `method(:...)` cannot resolve inside it; a class instance can. The
// instance stays alive while the request is in flight because makeWebRequest
// holds a reference to the Method it is given.
class AbsProgressListener {
    function initialize() {}
    function onResponse(code, data) {
        if (code != 200) {
            System.println("ABS progress update failed: " + code);
        }
    }
}
