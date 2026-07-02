using Toybox.Application;

// ---------------------------------------------------------------------------
// Application.Storage keys (object store). These hold app STATE (not user
// settings). Storage (not Properties) because these are code-managed and a
// sync/background process CAN write Storage but NOT Properties.
//
// SIZE MATTERS HERE - this layout exists because the first design stored one
// dictionary entry PER CHUNK in a single Storage value ({ "itemId:idx" =>
// 9-field dict }), and a long audiobook (The Algebraist: 19.4h = 389 chunks)
// made that value large enough that Storage.setValue() died with a FATAL,
// UNCATCHABLE "Out Of Memory Error" - reproduced in the simulator against
// this exact device profile (fenix8solar51mm), which gives an
// audioContentProvider app only 512KB. On the watch that crash surfaces as
// the native "Media Error Occurred" dialog + app exit. Storage values are
// also hard-limited to 32KB each (SDK-documented). So: everything below is
// O(books), never O(chunks) - chunk boundaries are DERIVED via the Chunks
// module, and per-chunk refIds live in one small per-book value.
// ---------------------------------------------------------------------------
module Store {
    // { itemId => { "inos" => [str], "durs" => [num], "title" => str,
    //   "done" => num } } - one small job per QUEUED book; chunk boundaries
    // derived on the fly, "done" is the resume cursor. ALWAYS read fresh and
    // read-modify-written per event, never held across events: a long-lived
    // in-memory snapshot persisted wholesale silently clobbers queue writes
    // made while a (background) sync is running.
    const SYNC_JOBS   = "syncJobs";
    // [ itemId, ... ] - books queued for DELETION (whole books only; the UI
    // has no per-chunk delete).
    const DELETE_LIST = "deleteList";
    // [ itemId, ... ] - books with downloaded chunks (index for the menu).
    const BOOK_INDEX  = "bookIndex";
    const APP_VERSION = "appVersion";  // Number, see Versions
    const SERVER      = "absServer";   // server URL saved by on-watch login
    const TOKEN       = "absToken";    // bearer token saved by on-watch login
}

// ---------------------------------------------------------------------------
// Application.Properties keys. These are USER-EDITABLE in Garmin Connect Mobile
// / Garmin Express and MUST be declared in resources/settings/properties.xml.
// Properties.getValue throws InvalidKeyException for an undeclared key.
// ---------------------------------------------------------------------------
module Settings {
    const SERVER_URL  = "absServerUrl";  // the sidecar's public URL (no trailing slash)
    const API_KEY     = "absApiKey";     // ABS long-lived API key, used as Bearer token
}

// Bump `current` whenever the stored data shape changes so stale caches reset.
module Versions {
    enum {
        V1 = 0,
        V2 = 1   // per-chunk SYNC_LIST/TRACKS dicts -> per-book jobs + BookStore
    }
    const current = V2;
    // Visible build tag - bump every build so we can confirm on-watch which
    // build is actually running (the MTP transfer is unreliable).
    const tag = "b26";
}
