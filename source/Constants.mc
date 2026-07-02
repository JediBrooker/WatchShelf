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
        V1 = 0
    }
    const current = V1;
    // Visible build tag - bump every build so we can confirm on-watch which
    // build is actually running (the MTP transfer is unreliable).
    const tag = "b25";
}

// Keys for a TrackInfo dict (one downloaded/queued CHAPTER = one Media track).
module TrackInfo {
    // We store the chunk PARAMETERS (not the full URL) so hundreds of chunks stay
    // small in Storage - the download URL (which embeds the long token) is rebuilt
    // at download time via AbsApi.sidecarChunkUrl().
    const TITLE      = "title";      // display title (this CHUNK - "Book Name 7")
    const BOOK_TITLE = "bookTitle";  // display title of the BOOK this chunk belongs to
    const TYPE       = "type";       // "mp3" -> Media.ENCODING_*
    const ITEM_ID    = "itemId";     // ABS libraryItemId - groups a book's chunks together
    const INO        = "ino";        // audio file inode
    const CSTART     = "cstart";     // chunk start within the file (seconds)
    const CEND       = "cend";       // chunk end within the file (seconds)
    const START      = "start";      // book-absolute start (seconds) for progress
    const CAN_SKIP   = "canSkip";
}
