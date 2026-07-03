using Toybox.Application;
using Toybox.Media;
using Toybox.System;

// Persistent store for DOWNLOADED books. Owns the media-cache lifecycle of
// every recorded chunk. Layout (see Constants.mc for the OOM post-mortem that
// forced O(books) storage):
//
//   "trk:"  + itemId          => { "title" => str, "author" => str, "durs" => [num, ...] }
//   "trkc:" + itemId + ":" + p => [ refId, ... ]   (page p, PAGE_SIZE entries)
//   "arta:" + itemId          => BitmapResource (player album art, ~ART_PX px)
//   "arti:" + itemId          => BitmapResource (menu icon, ~ICON_PX px)
//
// BitmapResource is a documented legal Storage value type (since CIQ 3.0.0).
// Art sizes are chosen to stay well under the 32KB-per-value cap even at
// 16bpp: 96px^2 * 2B ~= 18KB, 48px^2 * 2B ~= 4.6KB. Art is best-effort
// everywhere - a missing/failed bitmap must never break sync or playback.
//
// Chunks are stored as ARRAYS indexed by chunk number, in pages:
//  - position == chunk index, so re-recording a chunk after a crash/resume
//    OVERWRITES (and evicts the superseded cached item) instead of duplicating,
//    and "count == next chunk to download" holds by construction.
//  - pages keep every Storage value bounded (~11KB worst case at UUID-length
//    refIds) - a single flat per-book value would cross the documented
//    32KB-per-value cap on 33h+ books.
module BookStore {

    const PAGE_SIZE = 256;

    // Cover art pixel sizes (requested from the sidecar AND given to
    // makeImageRequest as :maxWidth/:maxHeight). Sized for the 32KB Storage
    // value cap - see the header comment.
    const ART_PX  = 96;
    const ICON_PX = 48;

    function key(itemId) {
        return "trk:" + itemId;
    }
    function pageKey(itemId, p) {
        return "trkc:" + itemId + ":" + p;
    }
    function artKey(itemId) {
        return "arta:" + itemId;
    }
    function iconKey(itemId) {
        return "arti:" + itemId;
    }

    // Book metadata { "title", "author", "durs" }, or null if nothing recorded
    // yet. "author" may be absent/null on records written by older builds.
    function get(itemId) {
        return Application.Storage.getValue(key(itemId));
    }

    function ensureMeta(itemId, title, author, durs) {
        if (get(itemId) == null) {
            Application.Storage.setValue(key(itemId),
                { "title" => title, "author" => author, "durs" => durs });
        }
    }

    // ---- cover art (best-effort, never load-bearing) -----------------------

    // Player-size album art / menu icon for a book, or null.
    function art(itemId) {
        return Application.Storage.getValue(artKey(itemId));
    }
    function icon(itemId) {
        return Application.Storage.getValue(iconKey(itemId));
    }

    // Persist a downloaded cover bitmap. Storage.setValue throws if the value
    // is too large or the object store is full - art is decoration, so any
    // failure is swallowed and the book simply keeps the placeholder.
    function saveArt(storageKey, bitmap) {
        try {
            Application.Storage.setValue(storageKey, bitmap);
        } catch (e) {
            System.println("art save failed: " + e.getErrorMessage());
        }
    }

    // Drop a book's art keys unless the book is actually downloaded (indexed).
    // Art is fetched when a job STARTS, before any chunk is recorded - so a
    // job abandoned early (Clear queue, stray-job self-heal) would otherwise
    // strand ~23KB of unreachable bitmaps forever: Storage has no key
    // iteration, and deleteBook (the normal cleanup) only runs for books the
    // user can see. Call this wherever a job dies before its book is indexed.
    function dropArtIfUnindexed(itemId) {
        var index = Application.Storage.getValue(Store.BOOK_INDEX);
        if (index != null) {
            for (var i = 0; i < index.size(); ++i) {
                if (index[i].equals(itemId)) { return; }
            }
        }
        Application.Storage.deleteValue(artKey(itemId));
        Application.Storage.deleteValue(iconKey(itemId));
    }

    // Downloaded-chunk count for a book (0 if none). Chunks download strictly
    // in order, so this is also the next chunk index to fetch.
    function count(itemId) {
        var total = 0;
        var p = 0;
        while (true) {
            var arr = Application.Storage.getValue(pageKey(itemId, p));
            if (arr == null) { return total; }
            total += arr.size();
            p += 1;
        }
        return total;
    }

    // Record chunk k's cache refId. Only page k/PAGE_SIZE is read-modified-
    // written, so the write stays small no matter how long the book is. If a
    // refId is already recorded at k (crash-window re-download), the OLD
    // cached item is evicted and the slot overwritten - no duplicates, ever.
    function saveChunk(itemId, k, refId) {
        var p = (k / PAGE_SIZE).toNumber();
        var idx = k - (p * PAGE_SIZE);
        var arr = Application.Storage.getValue(pageKey(itemId, p));
        if (arr == null) { arr = []; }
        if (idx < arr.size()) {
            var old = arr[idx];
            if ((old != null) && !old.equals(refId)) {
                Media.deleteCachedItem(new Media.ContentRef(old, Media.CONTENT_TYPE_AUDIO));
            }
            arr[idx] = refId;
        } else {
            // Defensive: pad any gap (shouldn't occur - downloads are strictly
            // in-order) so position always equals chunk index.
            while (arr.size() < idx) { arr.add(null); }
            arr.add(refId);
        }
        Application.Storage.setValue(pageKey(itemId, p), arr);
    }

    // Delete a book: evict every recorded chunk from the media cache, then
    // drop its pages and metadata. One page in memory at a time. Pages are
    // deleted in DESCENDING order: every reader (count/addLookup/this probe)
    // stops at the first missing page, so an interrupted delete must leave a
    // contiguous 0..m prefix for its retry to find and finish - deleting
    // ascending would strand pages >=1 forever (unreachable keys plus their
    // cached media) the moment page 0 vanished.
    function deleteBook(itemId) {
        var last = -1;
        while (Application.Storage.getValue(pageKey(itemId, last + 1)) != null) {
            last += 1;
        }
        for (var p = last; p >= 0; --p) {
            var arr = Application.Storage.getValue(pageKey(itemId, p));
            if (arr != null) {
                for (var i = 0; i < arr.size(); ++i) {
                    if (arr[i] != null) {
                        Media.deleteCachedItem(new Media.ContentRef(arr[i], Media.CONTENT_TYPE_AUDIO));
                    }
                }
            }
            Application.Storage.deleteValue(pageKey(itemId, p));
        }
        Application.Storage.deleteValue(key(itemId));
        Application.Storage.deleteValue(artKey(itemId));
        Application.Storage.deleteValue(iconKey(itemId));
    }

    // ---- BOOK_INDEX maintenance (the menu/playback book list) -------------

    function addToIndex(itemId) {
        var index = Application.Storage.getValue(Store.BOOK_INDEX);
        if (index == null) { index = []; }
        for (var i = 0; i < index.size(); ++i) {
            if (index[i].equals(itemId)) { return; }
        }
        index.add(itemId);
        Application.Storage.setValue(Store.BOOK_INDEX, index);
    }

    function removeFromIndex(itemId) {
        var index = Application.Storage.getValue(Store.BOOK_INDEX);
        if (index == null) { return; }
        var out = [];
        for (var i = 0; i < index.size(); ++i) {
            if (!index[i].equals(itemId)) { out.add(index[i]); }
        }
        Application.Storage.setValue(Store.BOOK_INDEX, out);
    }

    // Add every recorded refId of a book to `out` as { refId => true } - a
    // membership set for the end-of-sync orphan sweep.
    function addRefIds(itemId, out) {
        var p = 0;
        while (true) {
            var arr = Application.Storage.getValue(pageKey(itemId, p));
            if (arr == null) { return; }
            for (var i = 0; i < arr.size(); ++i) {
                if (arr[i] != null) { out[arr[i]] = true; }
            }
            p += 1;
        }
    }

    // Build { refId => [bookOrder, bookAbsoluteStartSeconds] } for one book
    // into `out` (a shared lookup dict used by playback). bookOrder is the
    // caller-supplied position of this book (its BOOK_INDEX slot) - playback
    // sorts on it NUMERICALLY. Never sort on the title string: Monkey C
    // String does not support relational operators at runtime (throws
    // UnexpectedTypeException; compiles silently at typecheck=0), and equal
    // titles would interleave two books chunk-by-chunk.
    function addLookup(itemId, order, out) {
        var meta = get(itemId);
        if (meta == null) { return; }
        var starts = Chunks.starts(meta["durs"]);
        var k = 0;
        var p = 0;
        while (true) {
            var arr = Application.Storage.getValue(pageKey(itemId, p));
            if (arr == null) { break; }
            for (var i = 0; i < arr.size(); ++i) {
                if ((arr[i] != null) && (k < starts.size())) {
                    out[arr[i]] = [order, starts[k]];
                }
                k += 1;
            }
            p += 1;
        }
    }
}
