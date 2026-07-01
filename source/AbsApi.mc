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
    function fileTrackUrl(itemId, audioFile) {
        var ino = audioFile["ino"];
        if (fileIsMp3(audioFile)) { return directFileUrl(itemId, ino); }
        if (fileIsAac(audioFile)) { return sidecarFileUrl(itemId, ino, "m4a"); }
        return sidecarFileUrl(itemId, ino, "mp3");
    }
    function fileTrackType(audioFile) {
        if (fileIsMp3(audioFile)) { return "mp3"; }
        if (fileIsAac(audioFile)) { return "adts"; }
        return "mp3";
    }

    // ---- URL builders ------------------------------------------------------

    // Direct ABS download of a whole audio file (mp3). Token in the query string
    // because makeWebRequest audio downloads are simplest with ?token=.
    // :fileid in the ABS route == the audioFile ino.
    function directFileUrl(itemId, ino) {
        return serverUrl() + "/api/items/" + itemId + "/file/" + ino + "/download?token=" + apiKey();
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

    // Progress sync goes through the SIDECAR. ABS's endpoint is PATCH
    // /api/me/progress/:id, but Monkey C's Communications has NO PATCH method
    // (only GET/POST/PUT/DELETE) and ABS ignores X-HTTP-Method-Override (verified
    // against the live server: POST -> 404). So the watch POSTs to the sidecar,
    // which issues the real PATCH to ABS server-side. If the sidecar isn't
    // configured, progress is skipped silently. currentTime is book-absolute sec.
    function patchProgress(itemId, currentTimeSec, durationSec) {
        if ((sidecarUrl() == null) || (sidecarKey() == null)) { return; }
        var params = { "itemId" => itemId, "currentTime" => currentTimeSec };
        if (durationSec != null) { params["duration"] = durationSec; }
        Communications.makeWebRequest(
            sidecarUrl() + "/progress?key=" + sidecarKey(),
            params,
            { :method => Communications.HTTP_REQUEST_METHOD_POST,
              :headers => { "Content-Type" => Communications.REQUEST_CONTENT_TYPE_JSON },
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
