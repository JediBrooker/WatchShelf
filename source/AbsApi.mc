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
    function serverUrl() {
        var v = _prop(Settings.SERVER_URL);
        // strip a single trailing slash so we can concat clean paths
        if ((v != null) && v.length() > 0 && v.substring(v.length() - 1, v.length()).equals("/")) {
            v = v.substring(0, v.length() - 1);
        }
        return v;
    }
    function apiKey()     { return _prop(Settings.API_KEY); }
    function sidecarUrl() {
        var v = _prop(Settings.SIDECAR_URL);
        if ((v != null) && v.length() > 0 && v.substring(v.length() - 1, v.length()).equals("/")) {
            v = v.substring(0, v.length() - 1);
        }
        return v;
    }
    function sidecarKey() { return _prop(Settings.SIDECAR_KEY); }

    function _prop(key) {
        // Properties.getValue throws if the key is undeclared; ours are declared
        // in properties.xml so this is safe, but guard for empty strings.
        var v = Application.Properties.getValue(key);
        if ((v != null) && (v instanceof Lang.String) && (v.length() == 0)) { return null; }
        return v;
    }

    function isConfigured() {
        return (serverUrl() != null) && (apiKey() != null);
    }

    // Common auth header for every request.
    function authHeaders() {
        return { "Authorization" => "Bearer " + apiKey() };
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
            { "minified" => "1", "limit" => "200", "sort" => "media.metadata.title" },
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

    // ---- per-file playback decision ---------------------------------------

    // ABS mimeType is derived from container format and can be misleading, so we
    // decide from codec + ext. mp3/aac in mp3/m4a/m4b/mp4 => the watch can play
    // the byte-exact file, so direct-download from ABS. Everything else
    // (flac/opus/vorbis/wma/...) must be transcoded by the sidecar to mp3.
    function fileIsDirectPlayable(audioFile) {
        var codec = _lower(audioFile["codec"]);
        var ext   = _lower(_ext(audioFile));
        var codecOk = (codec != null) && (codec.equals("mp3") || codec.equals("aac"));
        var extOk = (ext != null) &&
                    (ext.equals(".mp3") || ext.equals(".m4a") || ext.equals(".m4b") || ext.equals(".mp4"));
        return codecOk && extOk;
    }

    // Media.ENCODING_* the watch should declare for a direct-download of this
    // file. mp3 => MP3, aac/m4a/m4b => M4A. Sidecar output is always mp3.
    function encodingType(audioFile) {
        var ext = _lower(_ext(audioFile));
        if ((ext != null) && ext.equals(".mp3")) { return "mp3"; }
        return "m4a";
    }

    // ---- URL builders (one URL per CHAPTER) --------------------------------

    // Direct ABS download of a whole audio file. Token goes in the query string
    // because makeWebRequest audio downloads are simplest with ?token=.
    // :fileid in the ABS route == the audioFile ino.
    function directFileUrl(itemId, ino) {
        return serverUrl() + "/api/items/" + itemId + "/file/" + ino + "/download?token=" + apiKey();
    }

    // Sidecar chapter cut: returns a small, complete mp3 for exactly one chapter
    // so the user gets true chapter navigation and small transfers. The sidecar
    // holds the ABS token server-side; the watch authenticates with sidecarKey.
    // start/end are truncated to integer seconds (fine for a chapter cut).
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

    // ABS wants PATCH /api/me/progress/:libraryItemId, but Monkey C's
    // Communications has NO HTTP_REQUEST_METHOD_PATCH (only GET/PUT/POST/DELETE).
    // We POST with an X-HTTP-Method-Override: PATCH header, which Express
    // method-override middleware honours. If your ABS build does not honour the
    // override header, either enable method-override on the proxy or route
    // progress through the sidecar. (Flagged in apiConcerns.)
    // currentTime is book-absolute seconds. 200 with EMPTY body on success.
    function patchProgress(itemId, currentTimeSec, durationSec) {
        var params = { "currentTime" => currentTimeSec };
        if (durationSec != null) {
            params["duration"] = durationSec;
            if (durationSec > 0) {
                params["progress"] = currentTimeSec.toFloat() / durationSec.toFloat();
            }
        }
        Communications.makeWebRequest(
            serverUrl() + "/api/me/progress/" + itemId,
            params,
            { :method => Communications.HTTP_REQUEST_METHOD_POST,
              :headers => { "Authorization"          => "Bearer " + apiKey(),
                            "X-HTTP-Method-Override" => "PATCH",
                            "Content-Type"           => Communications.REQUEST_CONTENT_TYPE_JSON },
              :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON },
            new AbsProgressListener().method(:onResponse));
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
