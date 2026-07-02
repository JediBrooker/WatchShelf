using Toybox.Application;
using Toybox.Media;
using Toybox.System;

// Bridges the native media player to our downloaded chapter tracks and pushes
// playback position back to Audiobookshelf.
class ContentDelegate extends Media.ContentDelegate {

    private var mIterator;
    private var mProgressLookup; // { refId => [itemId, start] }, lazy

    function initialize() {
        ContentDelegate.initialize();
        mProgressLookup = null;
        resetContentIterator();
    }

    function getContentIterator() {
        return mIterator;
    }

    function resetContentIterator() {
        mIterator = new ContentIterator();
        return mIterator;
    }

    // Playback events. playbackPosition is seconds WITHIN the current chapter
    // track; ABS wants book-absolute time, so we add the chunk's start offset
    // from its book's BookStore record. We push progress on
    // notify/pause/stop/complete using the CONFIRMED named enum
    // (Media.SONG_EVENT_PLAYBACK_NOTIFY=3, COMPLETE=4, STOP=5, PAUSE=6)
    // rather than magic numbers.
    function onSong(refId, songEvent, playbackPosition) {
        if (songEvent == Media.SONG_EVENT_PLAYBACK_NOTIFY ||
            songEvent == Media.SONG_EVENT_COMPLETE ||
            songEvent == Media.SONG_EVENT_STOP ||
            songEvent == Media.SONG_EVENT_PAUSE) {
            syncProgress(refId, playbackPosition);
        }
    }

    function syncProgress(refId, positionInChapter) {
        if (!AbsApi.isConfigured()) { return; }

        // { refId => [itemId, start] }, built once per playback session (the
        // downloaded set can't change while the player is running - syncs
        // and playback are separate app modes).
        if (mProgressLookup == null) {
            mProgressLookup = {};
            var index = Application.Storage.getValue(Store.BOOK_INDEX);
            if (index == null) { index = []; }
            for (var b = 0; b < index.size(); ++b) {
                var perBook = {};
                BookStore.addLookup(index[b], b, perBook);
                var refIds = perBook.keys();
                for (var i = 0; i < refIds.size(); ++i) {
                    mProgressLookup[refIds[i]] = [index[b], perBook[refIds[i]][1]];
                }
            }
        }

        var hit = mProgressLookup[refId];
        if (hit == null) { return; }
        var absolute = hit[1] + positionInChapter;
        // We do not know the book's total duration here; passing null lets ABS
        // keep its stored duration and just update currentTime.
        AbsApi.patchProgress(hit[0], absolute, null);
    }

    function onShuffle() {
        mIterator.toggleShuffle();
    }

    // Audiobooks have no thumbs/ads, but the base class may call these.
    function onThumbsUp(refId) {}
    function onThumbsDown(refId) {}
    function onRepeat() {}
}
