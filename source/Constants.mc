using Toybox.Application;

// ---------------------------------------------------------------------------
// Application.Storage keys (object store). These hold app STATE (not user
// settings): the download queue, the delete queue, the map of downloaded
// chapter tracks, and the app version. Storage (not Properties) because these
// are code-managed and a sync/background process CAN write Storage but NOT
// Properties.
// ---------------------------------------------------------------------------
module Store {
    const SYNC_LIST   = "syncList";    // { trackKey => TrackInfo dict } queued to download
    const DELETE_LIST = "deleteList";  // [ refId, ... ] queued to delete from media cache
    const TRACKS      = "tracks";       // { refId => TrackInfo dict } already on device
    const APP_VERSION = "appVersion";  // Number, see Versions
}

// ---------------------------------------------------------------------------
// Application.Properties keys. These are USER-EDITABLE in Garmin Connect Mobile
// / Garmin Express and MUST be declared in resources/settings/properties.xml.
// Properties.getValue throws InvalidKeyException for an undeclared key.
// ---------------------------------------------------------------------------
module Settings {
    const SERVER_URL  = "absServerUrl";  // e.g. https://abs.example.com  (no trailing slash)
    const API_KEY     = "absApiKey";     // ABS long-lived API key, used as Bearer token
    const SIDECAR_URL = "sidecarUrl";    // e.g. https://abs.example.com/watchshelf-transcode
    const SIDECAR_KEY = "sidecarKey";    // shared secret the watch sends to the sidecar (?key=)
}

// Bump `current` whenever the stored data shape changes so stale caches reset.
module Versions {
    enum {
        V1 = 0
    }
    const current = V1;
}

// Keys for a TrackInfo dict (one downloaded/queued CHAPTER = one Media track).
module TrackInfo {
    const URL      = "url";        // fully-qualified download URL (direct ABS or sidecar)
    const TITLE    = "title";      // display title e.g. "Ch 3 - Wizards First Rule"
    const TYPE     = "type";       // "mp3" | "m4a" -> Media.ENCODING_*
    const ITEM_ID  = "itemId";     // ABS libraryItemId (li_...) for progress sync
    const START    = "start";      // chapter start offset within the book (seconds)
    const CAN_SKIP = "canSkip";    // Boolean, always true for audiobooks
}
