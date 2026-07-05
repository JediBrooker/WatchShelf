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
}
