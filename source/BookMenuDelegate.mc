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
                null, WatchUi.SLIDE_LEFT);
            return;
        }

        var chunk = 1800;  // 30-min chunks (~14MB at 64kbps mono); well under the watch limit
        var files = data["files"];
        var title = data["title"];
        if (title == null) { title = "Book"; }

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
                    TrackInfo.ITEM_ID  => mItemId,
                    TrackInfo.INO      => ino,
                    TrackInfo.CSTART   => pos,
                    TrackInfo.CEND     => end,
                    TrackInfo.START    => bookOffset + pos,
                    TrackInfo.TITLE    => title + " " + (idx + 1),
                    TrackInfo.TYPE     => "mp3",
                    TrackInfo.CAN_SKIP => true
                };
                idx += 1;
                pos = end;
            }
            bookOffset = bookOffset + dur;
        }

        if (idx == 0) {
            WatchUi.pushView(new ErrorView(WatchUi.loadResource(Rez.Strings.errNoAudio)), null, WatchUi.SLIDE_LEFT);
            return;
        }

        Application.Storage.setValue(Store.SYNC_LIST, syncList);
        WatchUi.pushView(new ErrorView(WatchUi.loadResource(Rez.Strings.queued)), null, WatchUi.SLIDE_LEFT);
        Communications.startSync();
    }

    function numOr(v, dflt) {
        if (v == null) { return dflt; }
        return v;
    }

    function onBack() {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
}
