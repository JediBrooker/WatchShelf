using Toybox.Application;
using Toybox.Communications;
using Toybox.WatchUi;

// Picked a book -> get its lean file list from the sidecar, split each file into
// 15-minute downloadable chunks, queue them (as small param sets, not full URLs),
// and run a background sync. Everything goes through the sidecar because most
// books here are single 200MB-1GB files the watch cannot download whole.
class BookMenuDelegate extends WatchUi.Menu2InputDelegate {

    private var mItemId;

    function initialize() {
        Menu2InputDelegate.initialize();
        mItemId = null;
    }

    function onSelect(item) {
        mItemId = item.getId();
        AbsApi.getFiles(mItemId, method(:onFiles));
    }

    function onFiles(code, data) {
        if (code != 200 || data == null || data["files"] == null || data["files"].size() == 0) {
            WatchUi.pushView(new ErrorView(WatchUi.loadResource(Rez.Strings.errDetail) + "\n(" + code + ")"),
                new ErrorViewDelegate(), WatchUi.SLIDE_LEFT);
            return;
        }

        // Song-length chunks (~3 min, ~1.4MB at 64kbps mono) - matching how real,
        // proven-working ACP apps like Spotify actually download audio (individual
        // songs, a few MB each), not the originally-assumed 30-min/~14MB chunks,
        // which failed immediately on real hardware ("Media Error Occurred").
        var chunk = 180;
        var files = data["files"];
        var title = data["title"];
        if (title == null) { title = "Book"; }

        // Re-selecting an already-fully-downloaded book must not silently queue
        // a full re-download of every chunk - tell the user it's already there
        // instead of burning battery/data re-syncing the same book.
        var expected = expectedChunkCount(files, chunk);
        if ((expected > 0) && (alreadyDownloadedCount() >= expected)) {
            WatchUi.pushView(new ErrorView(WatchUi.loadResource(Rez.Strings.alreadyDownloaded)),
                new ErrorViewDelegate(), WatchUi.SLIDE_LEFT);
            return;
        }

        var syncList = Application.Storage.getValue(Store.SYNC_LIST);
        if (syncList == null) { syncList = {}; }

        var bookOffset = 0;
        var idx = 0;
        for (var f = 0; f < files.size(); ++f) {
            var ino = files[f]["ino"];
            var dur = numOr(files[f]["duration"], 0).toNumber();
            if (dur <= 0) { continue; }
            var pos = 0;
            while (pos < dur) {
                var end = pos + chunk;
                if (end > dur) { end = dur; }
                syncList[mItemId + ":" + idx] = {
                    TrackInfo.ITEM_ID    => mItemId,
                    TrackInfo.INO        => ino,
                    TrackInfo.CSTART     => pos,
                    TrackInfo.CEND       => end,
                    TrackInfo.START      => bookOffset + pos,
                    TrackInfo.TITLE      => title + " " + (idx + 1),
                    TrackInfo.BOOK_TITLE => title,
                    TrackInfo.TYPE       => "mp3",
                    TrackInfo.CAN_SKIP   => true
                };
                idx += 1;
                pos = end;
            }
            bookOffset = bookOffset + dur;
        }

        if (idx == 0) {
            WatchUi.pushView(new ErrorView(WatchUi.loadResource(Rez.Strings.errNoAudio)), new ErrorViewDelegate(), WatchUi.SLIDE_LEFT);
            return;
        }

        Application.Storage.setValue(Store.SYNC_LIST, syncList);
        WatchUi.pushView(new ErrorView(WatchUi.loadResource(Rez.Strings.queued)), new ErrorViewDelegate(), WatchUi.SLIDE_LEFT);
        Communications.startSync();
    }

    function numOr(v, dflt) {
        if (v == null) { return dflt; }
        return v;
    }

    // Mirrors the chunking loop above exactly (count only, no allocation) so it
    // can never disagree with how many chunks a book actually splits into.
    function expectedChunkCount(files, chunk) {
        var count = 0;
        for (var f = 0; f < files.size(); ++f) {
            var dur = numOr(files[f]["duration"], 0).toNumber();
            if (dur <= 0) { continue; }
            var pos = 0;
            while (pos < dur) {
                var end = pos + chunk;
                if (end > dur) { end = dur; }
                count += 1;
                pos = end;
            }
        }
        return count;
    }

    function alreadyDownloadedCount() {
        var tracks = Application.Storage.getValue(Store.TRACKS);
        if (tracks == null) { return 0; }
        var count = 0;
        var refIds = tracks.keys();
        for (var i = 0; i < refIds.size(); ++i) {
            var info = tracks[refIds[i]];
            if ((info != null) && (info[TrackInfo.ITEM_ID] != null) && info[TrackInfo.ITEM_ID].equals(mItemId)) {
                count += 1;
            }
        }
        return count;
    }

    function onBack() {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
}
