using Toybox.Application;
using Toybox.Media;
using Toybox.System;

// Persistent store for DOWNLOADED books. Owns the media-cache lifecycle of
// every recorded chunk. Layout (see Constants.mc for the OOM post-mortem that
// forced O(books) storage):
//
//   "trk:"  + itemId          => { "title" => str, "author" => str,
//                                  "durs" => [num, ...], "first" => num }
//   "trkc:" + itemId + ":" + p       => [ refId, ... ]  PRIMARY variant, page p
//   "trkc:" + itemId + ":a:" + p     => [ refId, ... ]  ALTERNATE variant, page p
//   "arta:" + itemId          => BitmapResource (player album art, ~ART_PX px)
//   "arti:" + itemId          => BitmapResource (menu icon, ~ICON_PX px)
//
// BitmapResource is a documented legal Storage value type (since CIQ 3.0.0).
// Art sizes are chosen to stay well under the 32KB-per-value cap even at
// 16bpp: 96px^2 * 2B ~= 18KB, 48px^2 * 2B ~= 4.6KB. Art is best-effort
// everywhere - a missing/failed bitmap must never break sync or playback.
//
// Chunks are stored as ARRAYS indexed LOCALLY from meta.first, in pages:
//  - local position == global chunk index - first, so re-recording a chunk
//    after a crash/resume
//    OVERWRITES (and evicts the superseded cached item) instead of duplicating,
//    and "first + count == next chunk to download" holds by construction.
//  - `first` lets an in-progress ABS book omit its already-listened prefix
//    WITHOUT null-padding page 0 (which made count wrong and made first>=256
//    wholly unreachable because every reader stops at the first missing page).
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

    // ---- playback-speed variants -------------------------------------------
    // A book can hold TWO encodings of the same audio at different playback
    // speeds. The sidecar bakes the tempo into the bytes with ffmpeg and the
    // watch has no way to change it - Toybox.Media has NO playback-rate API at
    // all - so switching speed otherwise means re-downloading. Keeping the
    // previous encoding parked is what makes switching back to it instant.
    //
    // SLOT_PRIMARY uses the original page keys, so a book recorded before
    // variants existed reads correctly with no migration and no Versions bump
    // (which would have wiped every download).
    //
    // Only the ACTIVE variant is visible to playback: count(), first(),
    // saveChunk(), addLookup() and appendPlaylist() resolve it internally, so
    // every existing caller is unchanged. Exactly two places must span BOTH -
    // addRefIds(), or the end-of-sync orphan sweep evicts the parked copy the
    // moment it is no longer active, and deleteBook().
    const SLOT_PRIMARY = 0;
    const SLOT_ALT     = 1;

    function pageKeyFor(itemId, slot, p) {
        if (slot == SLOT_ALT) { return "trkc:" + itemId + ":a:" + p; }
        return "trkc:" + itemId + ":" + p;
    }
    function pageKey(itemId, p) {
        return pageKeyFor(itemId, activeSlot(itemId), p);
    }

    // Speed held in a slot, or null when that slot is empty. The primary's
    // speed is the legacy "speed" field; a record older than playback speed
    // has none and is 1.0x by definition.
    function slotSpeed(itemId, slot) {
        var meta = get(itemId);
        if (meta == null) { return null; }
        if (slot == SLOT_ALT) { return meta["alt"]; }
        return PlaybackSpeed.normalize(meta["speed"]);
    }

    // The slot playback should read. Absent "active" means the primary, which
    // is what every pre-variant record resolves to.
    function activeSlot(itemId) {
        var meta = get(itemId);
        if ((meta == null) || (meta["active"] == null)) { return SLOT_PRIMARY; }
        return (meta["active"] == SLOT_ALT) ? SLOT_ALT : SLOT_PRIMARY;
    }
    function activeSpeed(itemId) {
        var sp = slotSpeed(itemId, activeSlot(itemId));
        return (sp != null) ? sp : PlaybackSpeed.NORMAL;
    }

    // Which slot already holds this speed, or -1. An empty slot never matches.
    function slotForSpeed(itemId, speed) {
        var want = PlaybackSpeed.normalize(speed);
        if (countFor(itemId, SLOT_PRIMARY) > 0) {
            var sp = slotSpeed(itemId, SLOT_PRIMARY);
            if ((sp != null) && (sp == want)) { return SLOT_PRIMARY; }
        }
        if (countFor(itemId, SLOT_ALT) > 0) {
            var sa = slotSpeed(itemId, SLOT_ALT);
            if ((sa != null) && (sa == want)) { return SLOT_ALT; }
        }
        return -1;
    }
    function artKey(itemId) {
        return "arta:" + itemId;
    }
    function iconKey(itemId) {
        return "arti:" + itemId;
    }

    // Book metadata { "title", "author", "durs", "first", "speed" }, or null if
    // nothing recorded yet. "author" and "first" may be absent/null on records
    // written by older builds; an absent first means the legacy chunk 0.
    function get(itemId) {
        return Application.Storage.getValue(key(itemId));
    }

    function ensureMeta(itemId, title, author, durs, firstChunk, speed) {
        if (get(itemId) == null) {
            if (firstChunk == null) { firstChunk = 0; }
            Application.Storage.setValue(key(itemId),
                { "title" => title, "author" => author, "durs" => durs,
                  "first" => firstChunk, "speed" => PlaybackSpeed.normalize(speed) });
        }
    }

    // Global index of this book's first cached chunk. Legacy metadata predates
    // tail-only downloads and therefore always begins at chunk 0.
    function firstFor(itemId, slot) {
        var meta = get(itemId);
        if (meta == null) { return 0; }
        if (slot == SLOT_ALT) {
            return (meta["altFirst"] == null) ? 0 : meta["altFirst"];
        }
        return (meta["first"] == null) ? 0 : meta["first"];
    }
    function first(itemId) {
        return firstFor(itemId, activeSlot(itemId));
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

    // Actual downloaded-chunk count for a book (0 if none). Pages are local to
    // first(), so unlike the former null-padding idea this never counts omitted
    // listened chunks as if they occupied cache space.
    function countFor(itemId, slot) {
        var total = 0;
        var p = 0;
        while (true) {
            var arr = Application.Storage.getValue(pageKeyFor(itemId, slot, p));
            if (arr == null) { return total; }
            total += arr.size();
            p += 1;
        }
        return total;
    }
    function count(itemId) {
        return countFor(itemId, activeSlot(itemId));
    }

    // Chunks this book occupies across BOTH variants. The Chunks.MAX_TOTAL cap
    // is about cached audio, and a parked variant is still cached audio - so
    // the cap must see it or keeping one silently overruns the ceiling the cap
    // exists to defend.
    function totalChunks(itemId) {
        return countFor(itemId, SLOT_PRIMARY) + countFor(itemId, SLOT_ALT);
    }

    // Global next chunk to fetch for a contiguous cached suffix.
    function nextChunk(itemId) {
        return first(itemId) + count(itemId);
    }

    // Record GLOBAL chunk k's cache refId. Only the local page relative to
    // first() is read-modified-written, so the write stays small no matter how
    // long the book is. If a refId is already recorded at k (crash-window
    // re-download), the OLD
    // cached item is evicted and the slot overwritten - no duplicates, ever.
    function saveChunk(itemId, k, refId) {
        var local = k - first(itemId);
        if (local < 0) {
            System.println("saveChunk before first: " + k.toString());
            return;
        }
        var p = (local / PAGE_SIZE).toNumber();
        var idx = local - (p * PAGE_SIZE);
        var arr = Application.Storage.getValue(pageKey(itemId, p));
        if (arr == null) { arr = []; }
        if (idx < arr.size()) {
            var old = arr[idx];
            if ((old != null) && !old.equals(refId)) {
                Media.deleteCachedItem(new Media.ContentRef(old, Media.CONTENT_TYPE_AUDIO));
            }
            arr[idx] = refId;
        } else {
            // Defensive: pad any LOCAL gap (shouldn't occur - downloads are
            // strictly in order) so position remains relative to first().
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
        dropSlot(itemId, SLOT_PRIMARY);
        dropSlot(itemId, SLOT_ALT);
        Application.Storage.deleteValue(key(itemId));
        Application.Storage.deleteValue(artKey(itemId));
        Application.Storage.deleteValue(iconKey(itemId));
    }

    // Evict one variant: its cached audio, then its pages. Pages are deleted in
    // DESCENDING order because every reader stops at the first missing page, so
    // an interrupted delete must leave a contiguous 0..m prefix for its retry to
    // find - deleting ascending would strand pages >=1 forever, along with their
    // cached media. Leaves the book's metadata alone; callers that are removing
    // the whole book clear it separately.
    function dropSlot(itemId, slot) {
        var last = -1;
        while (Application.Storage.getValue(pageKeyFor(itemId, slot, last + 1)) != null) {
            last += 1;
        }
        for (var p = last; p >= 0; --p) {
            var arr = Application.Storage.getValue(pageKeyFor(itemId, slot, p));
            if (arr != null) {
                for (var i = 0; i < arr.size(); ++i) {
                    if (arr[i] != null) {
                        // One unrecognised id must not abort the whole delete.
                        // Media.deleteCachedItem throws when the id is not one
                        // the OS knows, and an aborted delete strands every
                        // remaining page - the leak this loop exists to avoid.
                        // An id the OS does not know has no cached bytes to
                        // free anyway, so skipping it costs nothing.
                        try {
                            Media.deleteCachedItem(new Media.ContentRef(arr[i], Media.CONTENT_TYPE_AUDIO));
                        } catch (e) {
                            System.println("evict skipped " + arr[i] + ": " + e.getErrorMessage());
                        }
                    }
                }
            }
            Application.Storage.deleteValue(pageKeyFor(itemId, slot, p));
        }
    }

    // Make an already-held variant active. Instant: the audio for that speed
    // is already on the watch, so nothing downloads. Returns false when that
    // speed is not held and the caller must queue a download instead.
    function switchTo(itemId, speed) {
        var slot = slotForSpeed(itemId, speed);
        if (slot < 0) { return false; }
        setActive(itemId, slot);
        return true;
    }

    function setActive(itemId, slot) {
        var meta = get(itemId);
        if (meta == null) { return; }
        meta["active"] = slot;
        Application.Storage.setValue(key(itemId), meta);
    }

    // Choose and clear the slot that a download at `speed` will fill, and make
    // it active. `keepOther` parks the currently active variant in the other
    // slot so switching back to it later is instant; false evicts it, which is
    // what happens when keeping it would breach Chunks.MAX_TOTAL.
    // Returns the slot now being filled.
    function beginVariant(itemId, speed, firstChunk, keepOther) {
        var want = PlaybackSpeed.normalize(speed);
        var active = activeSlot(itemId);
        var target = active;
        if (keepOther) {
            var activeSp = slotSpeed(itemId, active);
            // Re-downloading the SAME speed reuses its own slot - parking a
            // copy of the speed we are replacing would be pointless.
            if ((activeSp == null) || (activeSp != want)) {
                target = (active == SLOT_PRIMARY) ? SLOT_ALT : SLOT_PRIMARY;
            }
        }
        dropSlot(itemId, target);
        var meta = get(itemId);
        if (meta != null) {
            if (target == SLOT_ALT) {
                meta["alt"] = want;
                meta["altFirst"] = firstChunk;
            } else {
                meta["speed"] = want;
                meta["first"] = firstChunk;
            }
            meta["active"] = target;
            Application.Storage.setValue(key(itemId), meta);
        }
        return target;
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
    // CRITICAL: walks BOTH variants. The end-of-sync orphan sweep evicts any
    // cached audio no book's records claim, so if this reported only the active
    // variant the parked one would be swept at the very next sync - destroying
    // the copy the user is paying storage to keep, and turning an instant speed
    // switch back into a full re-download.
    function addRefIds(itemId, out) {
        addSlotRefIds(itemId, SLOT_PRIMARY, out);
        addSlotRefIds(itemId, SLOT_ALT, out);
    }

    function addSlotRefIds(itemId, slot, out) {
        var p = 0;
        while (true) {
            var arr = Application.Storage.getValue(pageKeyFor(itemId, slot, p));
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
        var spans = Chunks.spans(meta["durs"]);
        var firstChunk = first(itemId);
        var local = 0;
        var p = 0;
        while (true) {
            var arr = Application.Storage.getValue(pageKey(itemId, p));
            if (arr == null) { break; }
            for (var i = 0; i < arr.size(); ++i) {
                var k = firstChunk + local;
                if ((arr[i] != null) && (k < starts.size())) {
                    var span = (k < spans.size()) ? spans[k] : null;
                    out[arr[i]] = [order, starts[k], span, k];
                }
                local += 1;
            }
            p += 1;
        }
    }

    // Append recorded refs in their download order.
    function appendPlaylist(itemId, order, playlist, orders, startsOut, spansOut, globalsOut) {
        var meta = get(itemId);
        if (meta == null) { return; }
        var starts = Chunks.starts(meta["durs"]);
        var spans = Chunks.spans(meta["durs"]);
        var firstChunk = first(itemId);
        var local = 0;
        var p = 0;
        while (true) {
            var arr = Application.Storage.getValue(pageKey(itemId, p));
            if (arr == null) { break; }
            for (var i = 0; i < arr.size(); ++i) {
                var k = firstChunk + local;
                if ((arr[i] != null) && (k < starts.size())) {
                    playlist.add(arr[i]);
                    orders.add(order);
                    startsOut.add(starts[k]);
                    spansOut.add((k < spans.size()) ? spans[k] : null);
                    globalsOut.add(k);
                }
                local += 1;
            }
            p += 1;
        }
    }
}
