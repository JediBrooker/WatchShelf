using Toybox.Application;
using Toybox.Media;
using Toybox.System;

// Bridges the native media player to our downloaded chapter tracks and pushes
// playback position back to Audiobookshelf.
class ContentDelegate extends Media.ContentDelegate {

    private var mIterator;
    private var mProgressLookup; // refId => [item,start,duration,isFinal,span,speed], lazy
    private var mArtItemId;      // book whose cover is currently on the player
    private var mArgs;           // args for the NEXT iterator reset
    private var mSelectedItem;   // one book for this playback session
    private var mResumeGuardItem;
    private var mResumeFloor;    // exact saved position while first part replays
    private var mResumeGuardActive;
    private var mSessionFinishedItem; // final COMPLETE is terminal for this delegate
    private var mAwaitingResetStart;   // reset-after-final clears latch on START

    // args is the payload passed to Media.startPlayback (our BookActionMenu
    // sends { item, mode }); null when playback is launched from the native
    // Music widget. It flows on to the ContentIterator to position the cursor.
    function initialize(args) {
        ContentDelegate.initialize();
        mArgs = resolveArgs(args);
        mSelectedItem = (mArgs != null) ? mArgs["item"] : null;
        mProgressLookup = null;
        mArtItemId = null;
        mResumeGuardItem = null;
        mResumeFloor = 0;
        mResumeGuardActive = false;
        mSessionFinishedItem = null;
        mAwaitingResetStart = false;
        setResumeGuard(mArgs);
        resetContentIterator();
    }

    // Resolve a native-widget launch to one concrete book. Finished books are
    // never resumed at their duration (the old path mapped that to the final
    // part); an explicit stale Resume request degrades to start-over instead.
    function resolveArgs(args) {
        if (args != null) {
            var itemId = args["item"];
            var mode = args["mode"];
            if ((itemId != null) && (mode != null) && mode.equals("resume") &&
                Progress.isFinished(itemId)) {
                return { "item" => itemId, "mode" => "start" };
            }
            return args;
        }
        var r = Progress.bestResume();
        if (r != null) { return { "item" => r[0], "mode" => "resume" }; }
        var index = Application.Storage.getValue(Store.BOOK_INDEX);
        if ((index != null) && (index.size() > 0)) {
            return { "item" => index[0], "mode" => "start" };
        }
        return null;
    }

    function setResumeGuard(args) {
        if (args == null) { return; }
        var itemId = args["item"];
        var mode = args["mode"];
        if ((itemId == null) || (mode == null) || !mode.equals("resume")) { return; }
        var e = Progress.get(itemId);
        if ((e != null) && !Progress.entryFinished(e) && (e[0] > 0)) {
            mResumeGuardItem = itemId;
            mResumeFloor = e[0];
            mResumeGuardActive = true;
        }
    }

    function getContentIterator() {
        return mIterator;
    }

    function resetContentIterator() {
        var isReset = mIterator != null;
        mIterator = new ContentIterator(mArgs);
        // Garmin defines resetContentIterator as resetting to the beginning of
        // the CURRENT playlist. Consume the one-shot resume mode after initial
        // construction, but retain the selected-book filter for later resets.
        if ((mArgs != null) && (mArgs["item"] != null)) {
            mArgs = { "item" => mArgs["item"], "mode" => "start" };
        }
        // A later system reset is an intentional jump to playlist start, so an
        // old exact-resume floor must not suppress that new session's writes.
        // The constructor's first call keeps the guard set above.
        if (isReset) {
            mResumeGuardItem = null;
            mResumeFloor = 0;
            mResumeGuardActive = false;
            // Keep the final-event latch through the reset itself so trailing
            // callbacks from the completed iteration remain harmless. The
            // first START from the reset playlist proves a genuine restart.
            if (mSessionFinishedItem != null) { mAwaitingResetStart = true; }
        }
        return mIterator;
    }

    // Playback events. playbackPosition is seconds WITHIN the current chapter
    // track; ABS wants book-absolute time, so we add the chunk's start offset
    // from its book's BookStore record. We push progress on
    // notify/pause/stop/complete using the CONFIRMED named enum
    // (Media.SONG_EVENT_PLAYBACK_NOTIFY=3, COMPLETE=4, STOP=5, PAUSE=6)
    // rather than magic numbers.
    function onSong(refId, songEvent, playbackPosition) {
        if (songEvent == Media.SONG_EVENT_START) {
            if (mAwaitingResetStart) {
                mSessionFinishedItem = null;
                mAwaitingResetStart = false;
            }
            showArt(refId);
            return;
        }
        if (songEvent == Media.SONG_EVENT_PLAYBACK_NOTIFY ||
            songEvent == Media.SONG_EVENT_COMPLETE ||
            songEvent == Media.SONG_EVENT_STOP ||
            songEvent == Media.SONG_EVENT_PAUSE) {
            syncProgress(refId, songEvent, playbackPosition);
        }
    }

    // { refId => [itemId,start,bookDuration,isActualFinalPart,chunkSpan,speed] },
    // built once
    // per playback
    // session (the downloaded set can't change while the player is running -
    // syncs and playback are separate app modes). bookDuration is the sum of
    // the book's per-file durations, or null on records from older builds.
    function ensureLookup() {
        if (mProgressLookup != null) { return; }
        mProgressLookup = {};
        var index = Application.Storage.getValue(Store.BOOK_INDEX);
        if (index == null) { index = []; }
        for (var b = 0; b < index.size(); ++b) {
            if ((mSelectedItem == null) || !index[b].equals(mSelectedItem)) {
                continue;
            }
            var meta = BookStore.get(index[b]);
            var total = null;
            if ((meta != null) && (meta["durs"] != null)) {
                total = 0;
                var durs = meta["durs"];
                for (var d = 0; d < durs.size(); ++d) { total += durs[d]; }
            }
            var finalStart = null;
            if ((meta != null) && (meta["durs"] != null)) {
                var n = Chunks.total(meta["durs"]);
                if (n > 0) {
                    var last = Chunks.at(meta["durs"], n - 1);
                    if (last != null) { finalStart = last["start"]; }
                }
            }
            var perBook = {};
            BookStore.addLookup(index[b], b, perBook);
            var refIds = perBook.keys();
            for (var i = 0; i < refIds.size(); ++i) {
                var start = perBook[refIds[i]][1];
                var span = (perBook[refIds[i]].size() > 2) ? perBook[refIds[i]][2] : null;
                mProgressLookup[refIds[i]] = [index[b], start, total,
                    (finalStart != null) && (start == finalStart), span,
                    PlaybackSpeed.normalize((meta != null) ? meta["speed"] : null)];
            }
        }
    }

    function syncProgress(refId, songEvent, positionInChapter) {
        ensureLookup();
        var hit = mProgressLookup[refId];
        if (hit == null) { return; }
        var finished = (songEvent == Media.SONG_EVENT_COMPLETE) && hit[3];
        // Some firmware delivers a trailing notify/pause/stop for the final
        // cached part after its COMPLETE (and retained repeat state can even
        // start that same part again). Final completion is terminal for this
        // delegate: never let a later callback clear isFinished or move the
        // resume cursor backward. An explicit Start/Resume creates a fresh
        // ContentDelegate and therefore a fresh session latch.
        if ((mSessionFinishedItem != null) &&
            hit[0].equals(mSessionFinishedItem)) {
            return;
        }
        var speed = (hit.size() > 5) ? PlaybackSpeed.normalize(hit[5]) : PlaybackSpeed.NORMAL;
        var absolute = hit[1] + PlaybackSpeed.sourceSeconds(positionInChapter, speed);
        // A final COMPLETE is authoritative even on firmware that reports a
        // zero/rounded playbackPosition for AAC. Garmin also permits the
        // PLAYBACK_POSITION_END sentinel (-1) on COMPLETE; use the derived
        // chunk span for every completed non-final part so it can never push a
        // one-second-backward resume cursor between parts.
        if (finished && (hit[2] != null)) {
            absolute = hit[2];
        } else if ((songEvent == Media.SONG_EVENT_COMPLETE) &&
                   (hit.size() > 4) && (hit[4] != null) && (hit[4] > 0)) {
            absolute = hit[1] + hit[4];
        } else if ((hit[2] != null) && (absolute > hit[2])) {
            absolute = hit[2];
        }
        if (absolute < 0) { absolute = 0; }

        // Chunk-aligned resume deliberately replays up to ~3 minutes. Until it
        // catches the exact saved point, suppress local and ABS writes so that
        // replay cannot move the user's cross-device position backward. An
        // explicit Play-from-start session has no guard and may regress.
        if (mResumeGuardActive && (mResumeGuardItem != null) &&
            hit[0].equals(mResumeGuardItem)) {
            if (!finished && (absolute < mResumeFloor)) { return; }
            mResumeGuardActive = false;
        }
        if (finished) {
            mSessionFinishedItem = hit[0];
        }
        // Persist the position LOCALLY first (survives being offline, and even
        // an app kill mid-listen). The live push then clears the dirty flag if
        // it reaches ABS; if it doesn't (phoneless run), it stays queued and the
        // next sync flushes it. Same timestamp is used for both so the flush and
        // the eventual cross-device merge agree on when this was played.
        var ts = Progress.nowSec();
        Progress.record(hit[0], absolute, ts, finished);
        // The book's total duration (hit[2]) lets ABS compute a progress
        // fraction; null (older record without durations) keeps ABS's stored
        // duration.
        if (AbsApi.isConfigured()) {
            LiveProgress.submit(hit[0]);
        }
    }

    // A track started: put its book's cover on the native player screen
    // (Media.setAlbumArt is THE artwork mechanism for provider apps - there
    // is no per-track artwork field). null restores the system default art.
    // Skipped when the book hasn't changed - chunks are ~3 minutes apart.
    function showArt(refId) {
        ensureLookup();
        var hit = mProgressLookup[refId];
        var itemId = (hit != null) ? hit[0] : null;
        if ((itemId == null) && (mArtItemId == null)) { return; }
        if ((itemId != null) && (mArtItemId != null) && itemId.equals(mArtItemId)) { return; }
        mArtItemId = itemId;
        Media.setAlbumArt((itemId != null) ? BookStore.art(itemId) : null);
    }

    function onShuffle() {
        mIterator.toggleShuffle();
    }

    // Audiobooks have no thumbs/ads, but the base class may call these.
    function onThumbsUp(refId) {}
    function onThumbsDown(refId) {}
    function onRepeat() {}
}
