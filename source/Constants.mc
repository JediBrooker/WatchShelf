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
    // Queued download jobs live in JobStore (one job per key + a small
    // index) - O(files) inos/durs arrays per job must not share one value.
    // ALWAYS read queue state fresh per event, never held across events: a
    // long-lived in-memory snapshot persisted wholesale silently clobbers
    // queue writes made while a (background) sync is running.
    //
    // [ itemId, ... ] - books queued for DELETION (whole books only; the UI
    // has no per-chunk delete).
    const DELETE_LIST = "deleteList";
    // [ itemId, ... ] - books with downloaded chunks (index for the menu).
    const BOOK_INDEX  = "bookIndex";
    const APP_VERSION = "appVersion";  // Number, see Versions
    const SERVER      = "absServer";   // server URL saved by on-watch login
    const TOKEN       = "absToken";    // bearer token saved by on-watch login

    // Two-way play-progress state, O(books): one small dictionary keyed by
    // itemId (never per-chunk - see the OOM post-mortem above). See Progress.mc
    // for the value shape and the last-write-wins merge.
    const PROGRESS    = "prog";
    // One-shot flag: the user tapped "Sync now". Makes isSyncNeeded() true for
    // exactly one sync (onStartSync deletes it immediately), so an on-demand
    // progress exchange runs even when no download/delete is queued - WITHOUT
    // leaving isSyncNeeded() permanently true (which the OS would turn into
    // endless no-op syncs).
    const FORCE_SYNC  = "forceSync";
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
        V2 = 1,  // per-chunk SYNC_LIST/TRACKS dicts -> per-book jobs + BookStore
        V3 = 2,  // single SYNC_JOBS dict -> JobStore (one job per key + index)
        V4 = 3   // chunk format ADTS -> real M4A container (the native player
                 // derives track duration by parsing the cached file; raw ADTS
                 // has none, so no time indicator). Old cached chunks are the
                 // wrong format and must re-download - the version-change wipe
                 // in WatchShelfApp handles that.
    }
    const current = V4;
    // Visible build tag - bump every build so we can confirm on-watch which
    // build is actually running (the MTP transfer is unreliable). `current` is
    // NOT bumped for b34: two-way progress only ADDS new Storage keys (PROGRESS,
    // FORCE_SYNC) and never changes an existing value's shape, so the version
    // wipe (which would force every book to re-download) must not fire.
    const tag = "b34";
}
