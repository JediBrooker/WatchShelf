// Chunk math shared by BookMenuDelegate (queueing) and SyncDelegate
// (downloading). Chunk boundaries are DERIVED from the book's per-file
// durations every time they're needed, never materialized as per-chunk
// records - a 19h book is ~390 chunks, and storing (or even holding) one
// dictionary per chunk is what used to blow the 512KB audioContentProvider
// memory ceiling ("Media Error Occurred", reproduced in the simulator).
//
// The very FIRST chunk of a book is deliberately short so there's something
// to test playback with almost immediately; all later chunks are song-length
// (~3 min, ~2MB at 96kbps mono), matching how proven ACP apps like Spotify
// download audio. Both loops below MUST stay identical to each other.
module Chunks {
    const FIRST = 15;    // seconds, global chunk 0 only
    const LEN   = 180;   // seconds, every other chunk

    // Cap on TOTAL chunks on the watch (downloaded + queued, all books).
    // Playback builds O(total chunks) lookup structures inside the 512KB
    // audioContentProvider ceiling - validated safe at 1200 chunks in the
    // simulator; ~2500+ would re-approach the ceiling and resurrect the
    // uncatchable OOM this design exists to kill. 1500 chunks ~= 75 hours of
    // audio, plenty for a watch.
    const MAX_TOTAL = 1500;

    // True if two per-file duration arrays describe the same audio. Used to
    // detect server-side duration drift on a partially-downloaded book -
    // resumed chunk boundaries derive from the NEW durs while recorded start
    // offsets derive from the OLD ones, so a drifted book must restart clean.
    function same(dursA, dursB) {
        if ((dursA == null) || (dursB == null)) { return dursA == dursB; }
        if (dursA.size() != dursB.size()) { return false; }
        for (var i = 0; i < dursA.size(); ++i) {
            if (dursA[i] != dursB[i]) { return false; }
        }
        return true;
    }

    // Total chunk count across a book's files. durs = [seconds, ...].
    function total(durs) {
        var n = 0;
        for (var f = 0; f < durs.size(); ++f) {
            var d = durs[f];
            if (d <= 0) { continue; }
            var pos = 0;
            while (pos < d) {
                var size = (n == 0) ? FIRST : LEN;
                var end = pos + size;
                if (end > d) { end = d; }
                n += 1;
                pos = end;
            }
        }
        return n;
    }

    // Book-absolute start offset (seconds) of EVERY chunk, in one pass:
    // [ start0, start1, ... ]. Used to map recorded chunk indexes back to
    // positions for playback ordering and ABS progress sync.
    function starts(durs) {
        var out = [];
        var bookOffset = 0;
        for (var f = 0; f < durs.size(); ++f) {
            var d = durs[f];
            if (d <= 0) { continue; }
            var pos = 0;
            while (pos < d) {
                var size = (out.size() == 0) ? FIRST : LEN;
                var end = pos + size;
                if (end > d) { end = d; }
                out.add(bookOffset + pos);
                pos = end;
            }
            bookOffset = bookOffset + d;
        }
        return out;
    }

    // Boundaries of global chunk k, or null if k is out of range. Returns
    // { "file" => file index, "cstart"/"cend" => seconds within that file,
    //   "start" => absolute seconds within the whole book }.
    function at(durs, k) {
        var n = 0;
        var bookOffset = 0;
        for (var f = 0; f < durs.size(); ++f) {
            var d = durs[f];
            if (d <= 0) { continue; }
            var pos = 0;
            while (pos < d) {
                var size = (n == 0) ? FIRST : LEN;
                var end = pos + size;
                if (end > d) { end = d; }
                if (n == k) {
                    return {
                        "file"   => f,
                        "cstart" => pos,
                        "cend"   => end,
                        "start"  => bookOffset + pos
                    };
                }
                n += 1;
                pos = end;
            }
            bookOffset = bookOffset + d;
        }
        return null;
    }
}
