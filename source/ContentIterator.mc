using Toybox.Application;
using Toybox.Math;
using Toybox.Media;
using Toybox.System;

// Yields cached chapter tracks to the player. Order = the TRACKS map grouped by
// book (alphabetical by BOOK_TITLE), then sorted within each book by chapter
// START offset - so with more than one book downloaded, playback finishes one
// book before starting the next rather than interleaving their chapters (START
// resets to 0 for every book independently, so sorting by START alone would mix
// different books' chapters together in lockstep). Shuffle is available but off
// by default (nobody shuffles an audiobook).
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

    // Build the ordered playlist from the OS's OWN content cache, never our own
    // Storage bookkeeping - mirrors MonkeyMusic's initializePlaylist() exactly.
    // Store.TRACKS can drift out of sync with what the OS actually has cached
    // (a stale/removed entry, or a key that doesn't round-trip identically
    // through Storage's persistence layer); handing the OS back one of ITS OWN
    // ids is the only way to guarantee Media.getCachedContentObj() resolves it.
    // Store.TRACKS is used ONLY for sort metadata (bookTitle, chapterStart)
    // below, never as the id source. Insertion sort by (bookTitle,
    // chapterStart), plain statements (no fluent slice().add().addAll()
    // chaining, which relies on Array.add/addAll returning the array - they
    // return Void).
    function buildPlaylist() {
        mPlaylist = [];
        var tracks = Application.Storage.getValue(Store.TRACKS);
        if (tracks == null) { tracks = {}; }

        var refIds = [];
        var iter = Media.getContentRefIter({ :contentType => Media.CONTENT_TYPE_AUDIO });
        if (iter != null) {
            var ref = iter.next();
            while (ref != null) {
                refIds.add(ref.getId());
                ref = iter.next();
            }
        }

        for (var i = 0; i < refIds.size(); ++i) {
            var refId = refIds[i];

            var pos = mPlaylist.size();
            for (var j = 0; j < mPlaylist.size(); ++j) {
                if (before(tracks, refId, mPlaylist[j])) { pos = j; break; }
            }

            // Insert refId at pos by rebuilding the array in one pass.
            var rebuilt = new [mPlaylist.size() + 1];
            for (var k = 0; k < pos; ++k) { rebuilt[k] = mPlaylist[k]; }
            rebuilt[pos] = refId;
            for (var k = pos; k < mPlaylist.size(); ++k) { rebuilt[k + 1] = mPlaylist[k]; }
            mPlaylist = rebuilt;
        }
        mIndex = 0;
    }

    // True if refIdA sorts before refIdB: by book title first (so one book's
    // chapters never interleave with another's), then by chapter start.
    function before(tracks, refIdA, refIdB) {
        var titleA = bookTitleOf(tracks, refIdA);
        var titleB = bookTitleOf(tracks, refIdB);
        if (!titleA.equals(titleB)) {
            return titleA < titleB;
        }
        return startOf(tracks, refIdA) < startOf(tracks, refIdB);
    }

    function bookTitleOf(tracks, refId) {
        var info = tracks[refId];
        if ((info != null) && (info[TrackInfo.BOOK_TITLE] != null)) { return info[TrackInfo.BOOK_TITLE]; }
        return "";
    }

    function startOf(tracks, refId) {
        var info = tracks[refId];
        if ((info != null) && (info[TrackInfo.START] != null)) { return info[TrackInfo.START]; }
        return 0;
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
