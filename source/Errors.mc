using Toybox.WatchUi;

// Turns a makeWebRequest response code into wording a user can act on. `code` is
// the integer every CIQ web callback receives: 200 = OK, a POSITIVE value is an
// HTTP status, a NEGATIVE value is a Communications transport error. The two the
// user actually hits:
//
//   -104  BLE_CONNECTION_UNAVAILABLE - the watch can't reach the phone at all
//         (Garmin Connect Mobile not running / Bluetooth bridge down). Nothing
//         even left the watch. This is NOT a WatchShelf/ABS problem.
//   -300  NETWORK_REQUEST_TIMED_OUT - the request DID leave the watch (phone
//         bridge is fine) but nothing answered in time: the sidecar / tunnel is
//         down, slow, or unreachable. A "server" problem, not a phone one.
//   -400  INVALID_HTTP_BODY_IN_NETWORK_RESPONSE - reply wasn't the JSON we
//         expected (wrong URL, or the sidecar/ABS is unhappy). Grouped with 5xx.
//
// Unknown codes fall through to the caller's own generic message, and the raw
// number is ALWAYS appended so a genuine bug stays diagnosable on-device.
module Errors {

    // A short, actionable hint for a code we recognise, or null otherwise.
    function hint(code) {
        if (code == -104) {
            return WatchUi.loadResource(Rez.Strings.errPhone);
        }
        if ((code == -300) || (code == -400) || ((code >= 500) && (code <= 599))) {
            return WatchUi.loadResource(Rez.Strings.errServer);
        }
        return null;
    }

    // Full text for an error screen: the friendly hint when we recognise the
    // code, else the caller's generic fallback - either way with the raw number
    // appended (small, for support), so nothing becomes un-diagnosable.
    function message(fallbackRezId, code) {
        var h = hint(code);
        var base = (h != null) ? h : WatchUi.loadResource(fallbackRezId);
        return base + "\n(" + code + ")";
    }

    // Audio-transfer-specific wording. These codes are otherwise collapsed by
    // the native player into an opaque "Transfer failed" screen on some
    // firmware, so SyncDelegate persists this text for foreground inspection.
    function downloadHint(code) {
        if (code == -1000) { return "Watch storage is full"; }
        if (code == -1001) { return "HTTPS is required"; }
        if ((code == -1002) || (code == -1005)) { return "Watch rejected the audio file"; }
        if ((code == -1004) || (code == -3) || (code == -2)) { return "Connection dropped or timed out"; }
        if (code == -402) { return "Audio response was too large"; }
        if (code == -403) { return "Not enough watch memory"; }
        if (code == 400) { return "WatchShelf sidecar needs updating"; }
        if (code == 401) { return "Session expired; open Browse library"; }
        if (code == 404) { return "Book audio was not found"; }
        if (code == 502) { return "Sidecar could not transcode audio"; }
        var h = hint(code);
        return (h != null) ? h : "Audio download failed";
    }

    // Always retain the raw callback code for support, including code 200 with
    // null data (a malformed media response rather than a successful transfer).
    function downloadMessage(code) {
        return downloadHint(code) + " (" + code + ")";
    }
}
