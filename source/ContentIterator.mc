using Toybox.Application;
using Toybox.Math;
using Toybox.Media;
using Toybox.System;

// Yields cached chapter tracks to the player, grouped by book (alphabetical by
// title), sorted within each book by absolute start offset - so with more than
// one book downloaded, playback finishes one book before starting the next.
// Shuffle is available but off by default (nobody shuffles an audiobook).
//
// MEMORY: this runs in the playback context, which shares the 512KB
// audioContentProvider ceiling with the native player itself. Everything here
// stays O(cached chunks) in small parallel arrays of NUMBERS (playlist ids
// plus per-chunk book-slot/start-offset, kept for player metadata - ~12KB at
// the Chunks.MAX_TOTAL cap) - the per-book BookStore values hold only
// { refId => startSeconds }, and sorting is done in place with swaps (no
// per-insert array rebuilds). The old design deserialized one 9-field dict
// per chunk here and died with an uncatchable Out Of Memory Error the moment
// the player screen opened ("Media Error Occurred").
class ContentIterator extends Media.ContentIterator {

    private var mIndex;
    private var mPlaylist;    // [ refId, ... ] in play order
    private var mOrders;      // [ BOOK_INDEX slot, ... ] parallel to mPlaylist
    private var mStarts;      // [ book-absolute start sec, ... ] parallel too
    private var mBookTitles;  // [ title, ... ]  indexed by BOOK_INDEX slot (O(books))
    private var mBookAuthors; // [ author or null, ... ] same indexing
    private var mShuffling;

    function initialize() {
        ContentIterator.initialize();
        mIndex = 0;
        mShuffling = false;
        buildPlaylist();
    }

    // Audiobook-tuned controls: play/pause, prev/next chapter, 30s skip fwd/back.
    function getPlaybackProfile() {
        var profile = new Media.PlaybackProfile();
        profile.playbackControls = [
            Media.PLAYBACK_CONTROL_PLAYBACK,
            Media.PLAYBACK_CONTROL_PREVIOUS,
            Media.PLAYBACK_CONTROL_NEXT,
            Media.PLAYBACK_CONTROL_SKIP_FORWARD,
            Media.PLAYBACK_CONTROL_SKIP_BACKWARD
        ];
        profile.attemptSkipAfterThumbsDown = false;
        profile.requirePlaybackNotification = true;  // so onSong Notify fires for progress sync
        profile.playbackNotificationThreshold = 15;  // notify every ~15s of playback
        profile.skipPreviousThreshold = 3;
        // Do NOT set skipForward/BackwardTimeDelta: the system default is
        // already the 30s audiobook convention, and the SDK docs state that
        // overriding the value (even nominally) requires supplying custom
        // button icons via CustomButton playbackControls - the plain enums
        // above render the native 30s-badged buttons as-is.
        return profile;
    }

    function get() {
        return objAt(mIndex);
    }

    function next() {
        if (mIndex < (mPlaylist.size() - 1)) {
            ++mIndex;
            return objAt(mIndex);
        }
        return null;
    }

    function previous() {
        if (mIndex > 0) {
            --mIndex;
            return objAt(mIndex);
        }
        return null;
    }

    function peekNext() {
        return objAt(mIndex + 1);
    }

    function peekPrevious() {
        return objAt(mIndex - 1);
    }

    function canSkip() {
        return true; // chapters are always skippable
    }

    function shuffling() {
        return mShuffling;
    }

    function toggleShuffle() {
        if (mShuffling) {
            mShuffling = false;
            buildPlaylist();
        } else {
            shuffle();
            mShuffling = true;
        }
    }

    // ---- helpers -----------------------------------------------------------

    function objAt(idx) {
        if ((idx >= 0) && (idx < mPlaylist.size())) {
            try {
                var obj = Media.getCachedContentObj(new Media.ContentRef(mPlaylist[idx], Media.CONTENT_TYPE_AUDIO));
                if (obj != null) { decorate(obj, idx); }
                return obj;
            } catch (e) {
                // Media.getCachedContentObj is documented to throw if the id
                // isn't a Lang.String the OS recognizes - fall back to null
                // (a sanctioned return value) instead of an uncaught exception
                // reaching the native player.
                System.println("objAt failed for " + mPlaylist[idx] + ": " + e.getErrorMessage());
                return null;
            }
        }
        return null;
    }

    // The sidecar strips ALL tags from transcoded chunks (deliberately - a
    // Garmin-confirmed bug makes certain ID3 text frames break native playback
    // on real hardware), so without this the player screen shows blank
    // title/artist. Attach metadata at hand-off instead (the SubMusic
    // pattern): title = "<book> - <h:mm:ss>" where the timestamp is the
    // chunk's book-absolute start - with ~3-minute chunks that doubles as the
    // "where am I in the whole book" indicator next to the native player's
    // within-chunk position bar - artist = author, album = book title,
    // trackNumber = the chunk's position within its book.
    function decorate(obj, idx) {
        try {
            var meta = obj.getMetadata();
            if (meta == null) { meta = new Media.ContentMetadata(); }
            var title = mBookTitles[mOrders[idx]];
            meta.title = title + " - " + fmtTime(mStarts[idx]);
            meta.album = title;
            var author = mBookAuthors[mOrders[idx]];
            if (author != null) { meta.artist = author; }
            // trackNo relies on a book's chunks being contiguous in the
            // playlist - shuffle breaks that, so skip the number rather than
            // caption chunks with garbage positions.
            if (!mShuffling) { meta.trackNumber = trackNo(idx); }
            obj.setMetadata(meta);
        } catch (e) {
            // Metadata is decoration - never let it stop a track from
            // reaching the native player.
            System.println("decorate failed: " + e.getErrorMessage());
        }
    }

    // 1-based position of chunk idx within its book (chunks of one book are
    // contiguous in the sorted playlist; the backward scan is a few hundred
    // integer compares at worst, once per track hand-off).
    function trackNo(idx) {
        var b = mOrders[idx];
        var j = idx;
        while ((j > 0) && (mOrders[j - 1] == b)) { --j; }
        return idx - j + 1;
    }

    // Seconds -> "h:mm:ss" (or "m:ss" under an hour).
    function fmtTime(totalSec) {
        var s = totalSec.toNumber();
        var h = s / 3600;
        var m = (s % 3600) / 60;
        var sec = s % 60;
        if (h > 0) {
            return h.toString() + ":" + m.format("%02d") + ":" + sec.format("%02d");
        }
        return m.toString() + ":" + sec.format("%02d");
    }

    // Build the ordered playlist. Ids come from the OS's OWN content cache
    // (Media.getContentRefIter - mirrors MonkeyMusic), never our bookkeeping;
    // BookStore supplies only sort metadata (book order, chunk start). A
    // cached id BookStore doesn't know is SKIPPED - it's an orphan from a
    // crash window (cached but never recorded), not playable content we can
    // name or order. Sorted in place by (bookOrder, start) with parallel
    // arrays and swaps - NUMERIC keys only. Never sort on title strings:
    // Monkey C String has no relational operators at runtime (throws
    // UnexpectedTypeException, invisible at typecheck=0 - empirically
    // confirmed in the simulator), and identical titles would interleave two
    // books chunk-by-chunk.
    function buildPlaylist() {
        mPlaylist = [];
        mOrders = [];
        mStarts = [];
        mBookTitles = [];
        mBookAuthors = [];

        // One { refId => [bookOrder, start] } lookup across every downloaded
        // book; bookOrder = the book's BOOK_INDEX position. Titles/authors are
        // cached per book (O(books)) for the player metadata in decorate().
        var lookup = {};
        var index = Application.Storage.getValue(Store.BOOK_INDEX);
        if (index == null) { index = []; }
        for (var b = 0; b < index.size(); ++b) {
            BookStore.addLookup(index[b], b, lookup);
            var meta = BookStore.get(index[b]);
            var title = ((meta != null) && (meta["title"] != null)) ? meta["title"] : "Book";
            mBookTitles.add(title);
            mBookAuthors.add((meta != null) ? meta["author"] : null);
        }

        var iter = Media.getContentRefIter({ :contentType => Media.CONTENT_TYPE_AUDIO });
        if (iter != null) {
            var ref = iter.next();
            while (ref != null) {
                var refId = ref.getId();
                var info = lookup[refId];
                if (info != null) {
                    mPlaylist.add(refId);
                    mOrders.add(info[0]);
                    mStarts.add(info[1]);
                }
                ref = iter.next();
            }
        }

        // In-place insertion sort on the three parallel arrays: stable, no
        // allocations, numeric compares only. Chunks download (and cache) in
        // playlist order, so the input is near-sorted and this stays ~O(n).
        for (var i = 1; i < mPlaylist.size(); ++i) {
            var j = i;
            while (j > 0 && after(mOrders[j - 1], mStarts[j - 1], mOrders[j], mStarts[j])) {
                swap(mPlaylist, j); swap(mOrders, j); swap(mStarts, j);
                --j;
            }
        }
        mIndex = 0;
    }

    // True if (orderA, startA) sorts AFTER (orderB, startB): by book first
    // (one book's chapters never interleave with another's), then start.
    function after(orderA, startA, orderB, startB) {
        if (orderA != orderB) {
            return orderA > orderB;
        }
        return startA > startB;
    }

    function swap(arr, j) {
        var tmp = arr[j];
        arr[j] = arr[j - 1];
        arr[j - 1] = tmp;
    }

    // Fisher-Yates over ALL parallel arrays together - mOrders/mStarts must
    // follow their refIds or decorate() would caption every shuffled chunk
    // with the wrong book/position.
    function shuffle() {
        for (var i = mPlaylist.size() - 1; i > 0; --i) {
            var j = Math.rand() % (i + 1);
            swapAt(mPlaylist, i, j);
            swapAt(mOrders, i, j);
            swapAt(mStarts, i, j);
        }
        mIndex = 0;
    }

    function swapAt(arr, i, j) {
        var tmp = arr[i];
        arr[i] = arr[j];
        arr[j] = tmp;
    }
}
