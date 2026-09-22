using Toybox.Application;
using Toybox.System;
using Toybox.Time;

// Two-way play-progress state. O(books) - ONE small Storage dictionary keyed by
// itemId, never per-chunk (see Constants.mc for the OOM post-mortem that forced
// O(books) everywhere). One entry per book the user has played or resumed:
//
//   { itemId => [ positionSec, tsSec, dirty, finished? ] }
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
//   finished     optional Boolean. Missing on records from older builds and
//                therefore treated as false. A final-part COMPLETE sets true;
//                any later start-over playback clears it.
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

    function entryFinished(e) {
        return (e != null) && (e.size() > 3) && e[3];
    }

    function isFinished(itemId) {
        return entryFinished(get(itemId));
    }

    // Record a locally-observed position. Always marked dirty: the next sync
    // flushes it to ABS, and the live push (if online) clears it via markClean.
    function record(itemId, positionSec, tsSec, finished) {
        var m = all();
        m[itemId] = [positionSec, tsSec, true, finished == true];
        save(m);
    }

    // Drop a book's saved progress. Called when the book is deleted from the
    // watch so a stale entry can't linger and win bestResume() - which would
    // misdirect a later native-widget resume to a book that's no longer here.
    function remove(itemId) {
        var m = all();
        if (m.hasKey(itemId)) {
            m.remove(itemId);
            save(m);
        }
    }

    // Mark a book's write confirmed to ABS - but ONLY if the exact local write
    // is still current. Epoch seconds are 32-bit-safe but allow two callbacks
    // in one second; timestamp alone would let an older 200 clear a newer
    // position or final COMPLETE that still needs a retry.
    function markClean(itemId, tsSec, positionSec, finished) {
        var m = all();
        var e = m[itemId];
        if ((e != null) && e[2] && (e[1] == tsSec) &&
            (e[0] == positionSec) &&
            (entryFinished(e) == (finished == true))) {
            m[itemId] = [e[0], e[1], false, entryFinished(e)];
            save(m);
        }
    }

    // Count a server value displacing a DIRTY local write - listening that
    // happened on this watch and had not yet reached ABS.
    //
    // Why this exists (issue #61): the merge below trusts tsSec, and local
    // writes are stamped with the WATCH's clock. A watch running behind real
    // time can therefore lose genuine listening to an older server position,
    // silently and with no retry. Nobody has reported that - it was found by
    // reading the rule - so this measures it BEFORE anyone changes
    // last-write-wins semantics. If it never fires, the rule was fine.
    //
    // `skew` is how far ahead of our clock the server claims to be; `lost` is
    // how much further along we were. Positive `skew` together with positive
    // `lost` is the signature of clock skew rather than a genuine remote
    // update, because a real update from elsewhere normally moves progress
    // FORWARD, not backward.
    function noteConflict(localPos, localTs, serverPos, serverTs) {
        try {
            var prev = Application.Storage.getValue(Store.MERGE_CONFLICT);
            var count = ((prev != null) && (prev["count"] != null)) ? prev["count"] + 1 : 1;
            Application.Storage.setValue(Store.MERGE_CONFLICT, {
                "count" => count,
                "skew"  => serverTs - localTs,
                "lost"  => localPos - serverPos,
                "at"    => serverTs
            });
        } catch (ex) {
            // A diagnostic must never be able to break a sync.
            System.println("conflict note failed: " + ex.getErrorMessage());
        }
        System.println("progress conflict: local " + localPos + "@" + localTs
            + " displaced by server " + serverPos + "@" + serverTs);
    }

    // Read the diagnostic, or null if it has never fired.
    function conflicts() {
        return Application.Storage.getValue(Store.MERGE_CONFLICT);
    }
    function clearConflicts() {
        Application.Storage.deleteValue(Store.MERGE_CONFLICT);
    }

    // Merge a position pulled from ABS, last-write-wins by tsSec: a strictly
    // newer server value replaces ours (and is clean - no need to push it back);
    // an equal/older one is ignored so a fresh local listen is never regressed.
    function mergeServer(itemId, positionSec, tsSec, finished) {
        var m = all();
        var e = m[itemId];
        if ((e == null) || (tsSec > e[1])) {
            // Displacing a CLEAN entry is ordinary cross-device sync and is not
            // worth counting. Displacing a DIRTY one discards local listening -
            // that is the case #61 is about.
            if ((e != null) && e[2]) {
                noteConflict(e[0], e[1], positionSec, tsSec);
            }
            // A null flag is tolerated for an older sidecar/watch protocol and
            // preserves the local value. Current AbsApi always supplies it.
            var f = (finished != null) ? (finished == true) : entryFinished(e);
            m[itemId] = [positionSec, tsSec, false, f];
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

    // The most-recently-updated DOWNLOADED book as [itemId, positionSec], or
    // null - the book (and offset) to resume playback at across devices. Only
    // books still in BOOK_INDEX are considered: a progress entry for a deleted
    // book (or one downloaded on another device but not here) can't be resumed,
    // and letting it win would strand the null-args resume on a book that isn't
    // present (playback then silently starts a different book at 0).
    function bestResume() {
        var m = all();
        var ids = m.keys();
        var index = Application.Storage.getValue(Store.BOOK_INDEX);
        if (index == null) { index = []; }
        var bestId = null;
        var bestTs = null;
        for (var i = 0; i < ids.size(); ++i) {
            if (!_indexed(index, ids[i])) { continue; }
            var e = m[ids[i]];
            if (entryFinished(e)) { continue; }
            if ((bestTs == null) || (e[1] > bestTs)) {
                bestTs = e[1];
                bestId = ids[i];
            }
        }
        if (bestId == null) { return null; }
        return [bestId, m[bestId][0]];
    }

    function _indexed(index, itemId) {
        for (var i = 0; i < index.size(); ++i) {
            if (index[i].equals(itemId)) { return true; }
        }
        return false;
    }
}
