using Toybox.Application;
using Toybox.Math;
using Toybox.Media;

// Yields cached chapter tracks to the player. Order = the TRACKS map sorted by
// each track's chapter START offset so chapters play in book order. Shuffle is
// available but off by default (nobody shuffles an audiobook).
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
            return Media.getCachedContentObj(new Media.ContentRef(mPlaylist[idx], Media.CONTENT_TYPE_AUDIO));
        }
        return null;
    }

    // Build the ordered playlist from Storage TRACKS, sorted by chapter start.
    // Uses plain statements (no fluent slice().add().addAll() chaining, which
    // relies on Array.add/addAll returning the array - they return Void).
    function buildPlaylist() {
        mPlaylist = [];
        var tracks = Application.Storage.getValue(Store.TRACKS);
        if (tracks == null) { mIndex = 0; return; }

        var refIds = tracks.keys();
        // Simple insertion sort by TrackInfo.START (small N = chapters of a book).
        for (var i = 0; i < refIds.size(); ++i) {
            var refId = refIds[i];
            var start = startOf(tracks, refId);

            var pos = mPlaylist.size();
            for (var j = 0; j < mPlaylist.size(); ++j) {
                if (start < startOf(tracks, mPlaylist[j])) { pos = j; break; }
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
