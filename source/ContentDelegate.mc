using Toybox.Application;
using Toybox.Media;
using Toybox.System;

// Bridges the native media player to our downloaded chapter tracks and pushes
// playback position back to Audiobookshelf.
class ContentDelegate extends Media.ContentDelegate {

    private var mIterator;
    private var mProgressLookup; // { refId => [itemId, start, bookDuration] }, lazy
    private var mArtItemId;      // book whose cover is currently on the player
    private var mArgs;           // { item, mode } from startPlayback, or null

    // args is the payload passed to Media.startPlayback (our BookActionMenu
    // sends { item, mode }); null when playback is launched from the native
    // Music widget. It flows on to the ContentIterator to position the cursor.
    function initialize(args) {
        ContentDelegate.initialize();
        mArgs = args;
        mProgressLookup = null;
        mArtItemId = null;
        resetContentIterator();
    }

    function getContentIterator() {
        return mIterator;
    }

    function resetContentIterator() {
        mIterator = new ContentIterator(mArgs);
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
            showArt(refId);
            return;
        }
        if (songEvent == Media.SONG_EVENT_PLAYBACK_NOTIFY ||
            songEvent == Media.SONG_EVENT_COMPLETE ||
            songEvent == Media.SONG_EVENT_STOP ||
            songEvent == Media.SONG_EVENT_PAUSE) {
            syncProgress(refId, playbackPosition);
        }
    }

    // { refId => [itemId, start, bookDuration] }, built once per playback
    // session (the downloaded set can't change while the player is running -
    // syncs and playback are separate app modes). bookDuration is the sum of
    // the book's per-file durations, or null on records from older builds.
    function ensureLookup() {
        if (mProgressLookup != null) { return; }
        mProgressLookup = {};
        var index = Application.Storage.getValue(Store.BOOK_INDEX);
        if (index == null) { index = []; }
        for (var b = 0; b < index.size(); ++b) {
            var meta = BookStore.get(index[b]);
            var total = null;
            if ((meta != null) && (meta["durs"] != null)) {
                total = 0;
                var durs = meta["durs"];
                for (var d = 0; d < durs.size(); ++d) { total += durs[d]; }
            }
            var perBook = {};
            BookStore.addLookup(index[b], b, perBook);
            var refIds = perBook.keys();
            for (var i = 0; i < refIds.size(); ++i) {
                mProgressLookup[refIds[i]] = [index[b], perBook[refIds[i]][1], total];
            }
        }
    }

    function syncProgress(refId, positionInChapter) {
        if (!AbsApi.isConfigured()) { return; }
        ensureLookup();
        var hit = mProgressLookup[refId];
        if (hit == null) { return; }
        // If this chunk was resumed partway in via ActiveContent, onSong reports
        // playbackPosition RELATIVE to that start offset, so add it back to get
        // the true book-absolute position (0 for every normally-started chunk).
        var startOff = (mIterator != null) ? mIterator.resumeOffsetFor(refId) : 0;
        var absolute = hit[1] + startOff + positionInChapter;
        // Persist the position LOCALLY first (survives being offline, and even
        // an app kill mid-listen). The live push then clears the dirty flag if
        // it reaches ABS; if it doesn't (phoneless run), it stays queued and the
        // next sync flushes it. Same timestamp is used for both so the flush and
        // the eventual cross-device merge agree on when this was played.
        var ts = Progress.nowSec();
        Progress.record(hit[0], absolute, ts);
        // The book's total duration (hit[2]) lets ABS compute a progress
        // fraction; null (older record without durations) keeps ABS's stored
        // duration.
        AbsApi.patchProgress(hit[0], absolute, hit[2], ts);
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
