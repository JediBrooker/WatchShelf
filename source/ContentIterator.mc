using Toybox.Application;
using Toybox.Math;
using Toybox.Media;
using Toybox.System;

// Yields the cached parts of ONE selected book, sorted by absolute start
// offset. A playback session must never spill from the chosen audiobook into
// the next downloaded title. Shuffle remains available for compatibility with
// the native player, but is off by default (nobody shuffles an audiobook).
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
    private var mSpans;       // [ exact playable seconds, ... ] parallel too
    private var mGlobals;     // [ global derived chunk index, ... ] parallel
    private var mBookTitles;  // [ title, ... ]  indexed by BOOK_INDEX slot (O(books))
    private var mBookAuthors; // [ author or null, ... ] same indexing
    private var mBookDurations; // [ total seconds, ... ] same indexing
    private var mShuffling;
    private var mStartItem;    // book itemId to start at (from startPlayback), or null
    private var mStartMode;    // "resume" | "start" | null

    // args is the startPlayback payload: { item, mode } selects a specific book
    // and whether to resume or start it; null (native Music widget) resumes the
    // most-recently-progressed book.
    function initialize(args) {
        ContentIterator.initialize();
        mStartItem = null;
        mStartMode = null;
        if (args != null) {
            mStartItem = args["item"];
            mStartMode = args["mode"];
        }
        // A native-widget launch has no args. Resolve it to one concrete book
        // here as a defensive fallback (ContentDelegate normally does this so
        // a later reset can retain the same selection).
        if (mStartItem == null) {
            var r = Progress.bestResume();
            if (r != null) {
                mStartItem = r[0];
                mStartMode = "resume";
            } else {
                var index = Application.Storage.getValue(Store.BOOK_INDEX);
                if ((index != null) && (index.size() > 0)) {
                    mStartItem = index[0];
                    mStartMode = "start";
                }
            }
        }
        mIndex = 0;
        mShuffling = false;
        buildPlaylist();
    }

    // Audiobook-tuned controls: prev/next chapter, 30s skip fwd/back. NOTE we
    // do NOT list PLAYBACK_CONTROL_PLAYBACK: the native media player already
    // draws its own play/pause button, so including it here rendered a SECOND,
    // redundant pause button next to the first (confirmed on fenix8solar51mm).
    // playbackControls is for the AUXILIARY buttons around that built-in
    // play/pause, not the play/pause itself.
    function getPlaybackProfile() {
        var profile = new Media.PlaybackProfile();
        profile.playbackControls = [
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

    // Repeat is deliberately fixed off for audiobooks. The control is not
    // exposed in the profile, and returning an explicit state prevents a
    // repeat mode retained by the native player from looping the final part.
    function repeatMode() {
        return Media.REPEAT_MODE_OFF;
    }

    function get() {
        return validForward(mIndex, true);
    }

    function next() {
        return validForward(mIndex + 1, true);
    }

    function previous() {
        return validBackward(mIndex - 1, true);
    }

    function peekNext() {
        return validForward(mIndex + 1, false);
    }

    function peekPrevious() {
        return validBackward(mIndex - 1, false);
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

    // A missing/corrupt cached object is not the end of the playlist. Walk to
    // the next valid OS-owned Content object so one bad cache ref cannot make
    // playback stop after the preceding part. Peeks perform the same search
    // without moving the iterator cursor.
    function validForward(idx, move) {
        for (var i = idx; i < mPlaylist.size(); ++i) {
            var obj = objAt(i);
            if (obj != null) {
                if (move) { mIndex = i; }
                return obj;
            }
        }
        if (move) { mIndex = mPlaylist.size(); }
        return null;
    }

    function validBackward(idx, move) {
        for (var i = idx; i >= 0; --i) {
            var obj = objAt(i);
            if (obj != null) {
                if (move) { mIndex = i; }
                return obj;
            }
        }
        return null;
    }

    function objAt(idx) {
        if ((idx >= 0) && (idx < mPlaylist.size())) {
            try {
                var refId = mPlaylist[idx];
                var ref = new Media.ContentRef(refId, Media.CONTENT_TYPE_AUDIO);
                // Always return the ordinary cached Content object. ActiveContent
                // exact seeking is unreliable on FR965-class firmware: it can be
                // accepted here but fail later inside the native decoder, beyond
                // anything Monkey C can catch. Resume is therefore chunk-aligned
                // (at most ~3 minutes early), with ContentDelegate guarding the
                // exact saved position against progress regression.
                var obj = Media.getCachedContentObj(ref);
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
    // title/artist. Attach metadata at hand-off instead (the SubMusic pattern):
    // title = book name, artist = "author - NN% of book", album = book name,
    // trackNumber = the global part number. The native time/progress bar is
    // always scoped to the current cached part and cannot be overridden by an
    // audio provider, so the artist line carries coarse whole-book progress at
    // each part boundary instead.
    function decorate(obj, idx) {
        try {
            var meta = obj.getMetadata();
            if (meta == null) { meta = new Media.ContentMetadata(); }
            var title = mBookTitles[mOrders[idx]];
            meta.title = title;
            meta.album = title;
            var author = mBookAuthors[mOrders[idx]];
            var progress = overallProgress(idx);
            if ((author != null) && (author.length() > 0)) {
                meta.artist = author + " - " + progress;
            } else {
                meta.artist = progress;
            }
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

    function overallProgress(idx) {
        var total = mBookDurations[mOrders[idx]];
        var pct = 0;
        if ((total != null) && (total > 0)) {
            pct = ((mStarts[idx].toFloat() / total) * 100).toNumber();
            if (pct < 0) { pct = 0; }
            if (pct > 100) { pct = 100; }
        }
        return pct.toString() + "% of book";
    }

    // 1-based GLOBAL part number. Carry the derived index with the cached ref:
    // a missing earlier cache object must not renumber every later part.
    function trackNo(idx) {
        return mGlobals[idx] + 1;
    }

    // Build the selected book playlist from BookStore's sequential pages.
    function buildPlaylist() {
        mPlaylist = [];
        mOrders = [];
        mStarts = [];
        mSpans = [];
        mGlobals = [];
        mBookTitles = [];
        mBookAuthors = [];
        mBookDurations = [];

        var index = Application.Storage.getValue(Store.BOOK_INDEX);
        if (index == null) { index = []; }
        var selectedSlot = slotOf(mStartItem);
        for (var b = 0; b < index.size(); ++b) {
            var meta = BookStore.get(index[b]);
            var title = ((meta != null) && (meta["title"] != null)) ? meta["title"] : "Book";
            mBookTitles.add(title);
            mBookAuthors.add((meta != null) ? meta["author"] : null);
            var total = null;
            if ((meta != null) && (meta["durs"] != null)) {
                total = 0;
                var durs = meta["durs"];
                for (var d = 0; d < durs.size(); ++d) { total += durs[d]; }
            }
            mBookDurations.add(total);
            if (b == selectedSlot) {
                BookStore.appendPlaylist(index[b], b, mPlaylist, mOrders,
                    mStarts, mSpans, mGlobals);
            }
        }
        mIndex = 0;
        applyStart();
    }

    // Position the cursor for THIS playback session. "Resume" selects the
    // ordinary cached part containing the exact saved position and begins that
    // part at 0; ContentDelegate prevents this deliberate replay from regressing
    // the exact ABS position. "Start" chooses the earliest downloaded part
    // (which may be later than 0 for a tail-only download).
    function applyStart() {
        try {
            if (mStartItem == null) { mIndex = mPlaylist.size(); return; }
            var slot = slotOf(mStartItem);
            if (slot < 0) { mIndex = mPlaylist.size(); return; }
            var target = ((mStartMode != null) && mStartMode.equals("resume"))
                ? resumePosFor(mStartItem) : 0;
            positionAtBook(slot, target);
        } catch (e) {
            System.println("applyStart failed: " + e.getErrorMessage());
            mIndex = mPlaylist.size();
        }
    }

    // BOOK_INDEX slot (== sort order) for an itemId, or -1 if not downloaded.
    function slotOf(itemId) {
        var index = Application.Storage.getValue(Store.BOOK_INDEX);
        if (index == null) { return -1; }
        for (var i = 0; i < index.size(); ++i) {
            if (index[i].equals(itemId)) { return i; }
        }
        return -1;
    }

    // Saved book-absolute resume position (seconds) for a book, or 0. Finished
    // books are normally offered only "Play from start" by BookActionMenu.
    function resumePosFor(itemId) {
        var e = Progress.get(itemId); // [positionSec, tsSec, dirty, finished?]
        return (e != null) ? e[0] : 0;
    }

    // Put mIndex on the cached chunk that actually contains `target`. If target
    // precedes a tail-only download, choose its first available chunk. If target
    // is at/after the end of cached coverage (including a finished book at exact
    // duration), return an exhausted iterator instead of replaying the last part.
    function positionAtBook(slot, target) {
        var pick = -1;
        for (var i = 0; i < mPlaylist.size(); ++i) {
            if (mOrders[i] == slot) {
                if (target < mStarts[i]) {
                    // Start lies before the cached suffix, or inside a cache
                    // gap: continue from the next available part.
                    pick = i;
                    break;
                }
                // Span travels with the refId from BookStore. Deriving it from
                // the compressed playable ordinal is wrong after a corrupt or
                // OS-evicted earlier ref is skipped: later ordinals shift and
                // may cross a variable-length file boundary.
                var span = mSpans[i];
                if ((span > 0) && (target < (mStarts[i] + span))) {
                    pick = i;
                    break;
                }
            }
        }
        if (pick >= 0) {
            mIndex = pick;
        } else {
            mIndex = mPlaylist.size();
        }
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
            swapAt(mSpans, i, j);
            swapAt(mGlobals, i, j);
        }
        mIndex = 0;
    }

    function swapAt(arr, i, j) {
        var tmp = arr[i];
        arr[i] = arr[j];
        arr[j] = tmp;
    }
}
