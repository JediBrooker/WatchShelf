using Toybox.Application;
using Toybox.Media;

// Persistent store for DOWNLOADED books. Owns the media-cache lifecycle of
// every recorded chunk. Layout (see Constants.mc for the OOM post-mortem that
// forced O(books) storage):
//
//   "trk:"  + itemId          => { "title" => str, "durs" => [num, ...] }
//   "trkc:" + itemId + ":" + p => [ refId, ... ]   (page p, PAGE_SIZE entries)
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

    function key(itemId) {
        return "trk:" + itemId;
    }
    function pageKey(itemId, p) {
        return "trkc:" + itemId + ":" + p;
    }

    // Book metadata { "title", "durs" }, or null if nothing recorded yet.
    function get(itemId) {
        return Application.Storage.getValue(key(itemId));
    }

    function ensureMeta(itemId, title, durs) {
        if (get(itemId) == null) {
            Application.Storage.setValue(key(itemId), { "title" => title, "durs" => durs });
        }
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
