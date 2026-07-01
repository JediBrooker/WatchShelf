using Toybox.Application;
using Toybox.Media;
using Toybox.System;

// Bridges the native media player to our downloaded chapter tracks and pushes
// playback position back to Audiobookshelf.
class ContentDelegate extends Media.ContentDelegate {

    private var mIterator;

    function initialize() {
        ContentDelegate.initialize();
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
    // track; ABS wants book-absolute time, so we add the chapter's start offset
    // stored in TrackInfo. We push progress on notify/pause/stop/complete using
    // the CONFIRMED named enum (Media.SONG_EVENT_PLAYBACK_NOTIFY=3, COMPLETE=4,
    // STOP=5, PAUSE=6) rather than magic numbers.
    function onSong(refId, songEvent, playbackPosition) {
        if (songEvent == Media.SONG_EVENT_PLAYBACK_NOTIFY ||
            songEvent == Media.SONG_EVENT_COMPLETE ||
            songEvent == Media.SONG_EVENT_STOP ||
            songEvent == Media.SONG_EVENT_PAUSE) {
            syncProgress(refId, playbackPosition);
        }
    }

    function syncProgress(refId, positionInChapter) {
        var tracks = Application.Storage.getValue(Store.TRACKS);
        if (tracks == null) { return; }
        var info = tracks[refId];
        if (info == null) { return; }

        if (!AbsApi.isConfigured()) { return; }

        var start = info[TrackInfo.START];
        if (start == null) { start = 0; }
        var absolute = start + positionInChapter;

        // We do not know the book's total duration here; passing null lets ABS
        // keep its stored duration and just update currentTime.
        AbsApi.patchProgress(info[TrackInfo.ITEM_ID], absolute, null);
    }

    function onShuffle() {
        mIterator.toggleShuffle();
    }

    // Audiobooks have no thumbs/ads, but the base class may call these.
    function onThumbsUp(refId) {}
    function onThumbsDown(refId) {}
    function onRepeat() {}
}
