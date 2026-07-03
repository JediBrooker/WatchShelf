using Toybox.Application;
using Toybox.Time;

// Two-way play-progress state. O(books) - ONE small Storage dictionary keyed by
// itemId, never per-chunk (see Constants.mc for the OOM post-mortem that forced
// O(books) everywhere). One entry per book the user has played or resumed:
//
//   { itemId => [ positionSec, tsSec, dirty ] }
//
//   positionSec  book-absolute playback position in seconds - the resume point.
//   tsSec        when that position was set, in EPOCH SECONDS. This is the same
//                clock ABS records as MediaProgress.lastUpdate (the sidecar
//                converts sec<->ms at the edge), so cross-device last-write-wins
//                is a plain numeric compare. Watch writes stamp Time.now(); a
//                server pull carries ABS's own lastUpdate.
//   dirty        true  = written locally but not yet confirmed to ABS (must be
//                        flushed on the next sync);
//                false = in sync with ABS.
//
// Seconds (not ms) is deliberate: an epoch-ms value overflows the watch's 32-bit
// Number and JSON-decodes to a lossy Float, which would corrupt LWW ordering.
// Epoch seconds stays an exact Number, and the sidecar does the *1000 / /1000.
module Progress {

    function nowSec() {
        return Time.now().value();
    }

    function all() {
        var m = Application.Storage.getValue(Store.PROGRESS);
        if (m == null) { return {}; }
        return m;
    }

    function save(m) {
        Application.Storage.setValue(Store.PROGRESS, m);
    }

    function get(itemId) {
        return all()[itemId];
    }

    // Record a locally-observed position. Always marked dirty: the next sync
    // flushes it to ABS, and the live push (if online) clears it via markClean.
    function record(itemId, positionSec, tsSec) {
        var m = all();
        m[itemId] = [positionSec, tsSec, true];
        save(m);
    }

    // Mark a book's write confirmed to ABS - but ONLY if no NEWER local write
    // landed while the request was in flight. A later record() bumps tsSec, so a
    // stale 200 for an older position must not clear the newer dirty one.
    function markClean(itemId, tsSec) {
        var m = all();
        var e = m[itemId];
        if ((e != null) && e[2] && (e[1] <= tsSec)) {
            m[itemId] = [e[0], e[1], false];
            save(m);
        }
    }

    // Merge a position pulled from ABS, last-write-wins by tsSec: a strictly
    // newer server value replaces ours (and is clean - no need to push it back);
    // an equal/older one is ignored so a fresh local listen is never regressed.
    function mergeServer(itemId, positionSec, tsSec) {
        var m = all();
        var e = m[itemId];
        if ((e == null) || (tsSec > e[1])) {
            m[itemId] = [positionSec, tsSec, false];
            save(m);
        }
    }

    // Any local write still awaiting a flush? Drives isSyncNeeded().
    function hasDirty() {
        var m = all();
        var ids = m.keys();
        for (var i = 0; i < ids.size(); ++i) {
            if (m[ids[i]][2]) { return true; }
        }
        return false;
    }

    function dirtyIds() {
        var m = all();
        var ids = m.keys();
        var out = [];
        for (var i = 0; i < ids.size(); ++i) {
            if (m[ids[i]][2]) { out.add(ids[i]); }
        }
        return out;
    }

    // The most-recently-updated book as [itemId, positionSec], or null - the
    // book (and offset) to resume playback at across devices.
    function bestResume() {
        var m = all();
        var ids = m.keys();
        var bestId = null;
        var bestTs = null;
        for (var i = 0; i < ids.size(); ++i) {
            var e = m[ids[i]];
            if ((bestTs == null) || (e[1] > bestTs)) {
                bestTs = e[1];
                bestId = ids[i];
            }
        }
        if (bestId == null) { return null; }
        return [bestId, m[bestId][0]];
    }
}
