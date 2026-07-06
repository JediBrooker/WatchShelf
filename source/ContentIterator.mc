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
    private var mResumeRefId;  // the ONE chunk to start partway in (or null)
    private var mResumeOffset; // seconds into that chunk (Number); 0 = none
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

    function get() {
        return objAt(mIndex);
    }

    function next() {
        if (mIndex < (mPlaylist.size() - 1)) {
            ++mIndex;
            clearResume(); // the mid-chunk offset applies only to the first chunk
            return objAt(mIndex);
        }
        return null;
    }

    function previous() {
        if (mIndex > 0) {
            --mIndex;
            clearResume();
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
                var refId = mPlaylist[idx];
                var ref = new Media.ContentRef(refId, Media.CONTENT_TYPE_AUDIO);
                // Precise resume: this ONE chunk starts partway in. ActiveContent
                // (API 3.0.0+) carries a start position in seconds, so the native
                // player begins there instead of at 0. If it's unsupported on this
                // device or throws, fall through to the plain cached obj - playback
                // then resumes at the chunk's start (~offset early), never crashes.
                if ((mResumeRefId != null) && refId.equals(mResumeRefId) && (mResumeOffset > 0)) {
                    try {
                        return new Media.ActiveContent(ref, resumeMetadata(idx), mResumeOffset);
                    } catch (e2) {
                        System.println("ActiveContent resume failed: " + e2.getErrorMessage());
                    }
                }
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
    // title = book name, artist = author, album = book name, trackNumber = the
    // chunk's position within its book. (The title used to append the chunk's
    // book-absolute timestamp as a coarse position readout; dropped for a clean
    // "book - author" screen - the native player still shows within-chunk time.)
    function decorate(obj, idx) {
        try {
            var meta = obj.getMetadata();
            if (meta == null) { meta = new Media.ContentMetadata(); }
            var title = mBookTitles[mOrders[idx]];
            meta.title = title;
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

    // Fresh ContentMetadata for a chunk, used for the ActiveContent resume path
    // (which takes metadata at construction, unlike the cached-obj path that
    // decorates in place). Cached chunks carry no tags - the sidecar strips them
    // - so building fresh loses nothing. Mirrors decorate()'s captioning.
    function resumeMetadata(idx) {
        var meta = new Media.ContentMetadata();
        var title = mBookTitles[mOrders[idx]];
        meta.title = title;
        meta.album = title;
        var author = mBookAuthors[mOrders[idx]];
        if (author != null) { meta.artist = author; }
        if (!mShuffling) { meta.trackNumber = trackNo(idx); }
        return meta;
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
        clearResume();
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
        applyStart();
    }

    // Position the cursor for THIS playback session. If a specific book was
    // chosen (BookActionMenu -> startPlayback { item, mode }), start it at its
    // synced position ("resume") or at 0 ("start"). With no book (native Music
    // widget / null args), resume the most-recently-progressed book. Best-effort
    // throughout: any problem leaves the cursor at 0, never a crash.
    function applyStart() {
        try {
            var slot;
            var target;
            if (mStartItem != null) {
                slot = slotOf(mStartItem);
                if (slot < 0) { return; } // chosen book isn't downloaded
                target = ((mStartMode != null) && mStartMode.equals("resume"))
                    ? resumePosFor(mStartItem) : 0;
            } else {
                var r = Progress.bestResume(); // [itemId, positionSec] or null
                if (r == null) { return; }
                slot = slotOf(r[0]);
                if (slot < 0) { return; }
                target = r[1];
            }
            positionAtBook(slot, target);
        } catch (e) {
            System.println("applyStart failed: " + e.getErrorMessage());
            mIndex = 0;
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

    // Saved book-absolute resume position (seconds) for a book, or 0.
    function resumePosFor(itemId) {
        var e = Progress.get(itemId); // [positionSec, tsSec, dirty] or null
        return (e != null) ? e[0] : 0;
    }

    // Put mIndex on the chunk of book `slot` that contains `target` seconds, and
    // (via ActiveContent, see objAt) start it partway in for an exact resume. A
    // book's chunks are contiguous and ascending in the sorted playlist. Falls
    // back to the book's first cached chunk when target precedes it (e.g. "start"
    // on a book whose head isn't at absolute 0).
    function positionAtBook(slot, target) {
        var first = -1;
        var pick = -1;
        for (var i = 0; i < mPlaylist.size(); ++i) {
            if (mOrders[i] == slot) {
                if (first < 0) { first = i; }
                if (mStarts[i] <= target) { pick = i; } else { break; }
            } else if (first >= 0) {
                break;
            }
        }
        if (pick < 0) { pick = first; }
        if (pick >= 0) {
            mIndex = pick;
            var off = (target - mStarts[pick]).toNumber(); // seconds into chunk
            if (off > 0) {
                mResumeRefId = mPlaylist[pick];
                mResumeOffset = off;
            }
        }
    }

    // Resume offset (seconds) to add for `refId`, else 0. ContentDelegate needs
    // it because ActiveContent reports onSong playbackPosition RELATIVE to the
    // configured start, so the true in-chunk offset is start + position.
    function resumeOffsetFor(refId) {
        if ((mResumeRefId != null) && refId.equals(mResumeRefId)) { return mResumeOffset; }
        return 0;
    }

    function clearResume() {
        mResumeRefId = null;
        mResumeOffset = 0;
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
        clearResume(); // shuffled playback doesn't mid-chunk resume
    }

    function swapAt(arr, i, j) {
        var tmp = arr[i];
        arr[i] = arr[j];
        arr[j] = tmp;
    }
}
