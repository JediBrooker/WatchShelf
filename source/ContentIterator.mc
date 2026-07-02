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
// stays O(cached chunks) in small parallel arrays - the per-book BookStore
// values hold only { refId => startSeconds }, and sorting is done in place
// with swaps (no per-insert array rebuilds). The old design deserialized one
// 9-field dict per chunk here and died with an uncatchable Out Of Memory
// Error the moment the player screen opened ("Media Error Occurred").
class ContentIterator extends Media.ContentIterator {

    private var mIndex;
    private var mPlaylist;   // [ refId, ... ] in play order
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
        // 30s jumps are the audiobook convention (fields since API 4.2.4). Set
        // defensively via has-check so builds targeting older SDKs still compile.
        if (profile has :skipForwardTimeDelta) {
            profile.skipForwardTimeDelta = 30;
        }
        if (profile has :skipBackwardTimeDelta) {
            profile.skipBackwardTimeDelta = 30;
        }
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
                return Media.getCachedContentObj(new Media.ContentRef(mPlaylist[idx], Media.CONTENT_TYPE_AUDIO));
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
        var orders = [];
        var starts = [];

        // One { refId => [bookOrder, start] } lookup across every downloaded
        // book; bookOrder = the book's BOOK_INDEX position.
        var lookup = {};
        var index = Application.Storage.getValue(Store.BOOK_INDEX);
        if (index == null) { index = []; }
        for (var b = 0; b < index.size(); ++b) {
            BookStore.addLookup(index[b], b, lookup);
        }

        var iter = Media.getContentRefIter({ :contentType => Media.CONTENT_TYPE_AUDIO });
        if (iter != null) {
            var ref = iter.next();
            while (ref != null) {
                var refId = ref.getId();
                var info = lookup[refId];
                if (info != null) {
                    mPlaylist.add(refId);
                    orders.add(info[0]);
                    starts.add(info[1]);
                }
                ref = iter.next();
            }
        }

        // In-place insertion sort on the three parallel arrays: stable, no
        // allocations, numeric compares only. Chunks download (and cache) in
        // playlist order, so the input is near-sorted and this stays ~O(n).
        for (var i = 1; i < mPlaylist.size(); ++i) {
            var j = i;
            while (j > 0 && after(orders[j - 1], starts[j - 1], orders[j], starts[j])) {
                swap(mPlaylist, j); swap(orders, j); swap(starts, j);
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

    function shuffle() {
        for (var i = mPlaylist.size() - 1; i > 0; --i) {
            var j = Math.rand() % (i + 1);
            var tmp = mPlaylist[i];
            mPlaylist[i] = mPlaylist[j];
            mPlaylist[j] = tmp;
        }
        mIndex = 0;
    }
}
