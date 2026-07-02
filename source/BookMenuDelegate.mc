using Toybox.Application;
using Toybox.Communications;
using Toybox.WatchUi;

// Picked a book -> get its lean file list from the sidecar, store ONE small
// per-book job (file inos + durations + title + resume cursor), and run a
// background sync. Chunk boundaries are derived by the Chunks module at
// download time - never stored per-chunk (see Constants.mc for the OOM
// post-mortem that forced this). Everything goes through the sidecar because
// most books here are single 200MB-1GB files the watch cannot download whole.
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

        var files = data["files"];
        var title = data["title"];
        if (title == null) { title = "Book"; }

        var inos = [];
        var durs = [];
        for (var f = 0; f < files.size(); ++f) {
            var dur = numOr(files[f]["duration"], 0).toNumber();
            if (dur <= 0) { continue; }
            inos.add(files[f]["ino"]);
            durs.add(dur);
        }

        var expected = Chunks.total(durs);
        if (expected == 0) {
            WatchUi.pushView(new ErrorView(WatchUi.loadResource(Rez.Strings.errNoAudio)), new ErrorViewDelegate(), WatchUi.SLIDE_LEFT);
            return;
        }

        // Re-selecting an already-fully-downloaded book must not silently queue
        // a full re-download - tell the user it's already there instead.
        var have = BookStore.count(mItemId);
        if (have >= expected) {
            WatchUi.pushView(new ErrorView(WatchUi.loadResource(Rez.Strings.alreadyDownloaded)),
                new ErrorViewDelegate(), WatchUi.SLIDE_LEFT);
            return;
        }

        // One small job per book. "done" starts at the already-downloaded chunk
        // count so an interrupted book resumes where it left off (chunks always
        // download in order, so count == next index).
        var jobs = Application.Storage.getValue(Store.SYNC_JOBS);
        if (jobs == null) { jobs = {}; }
        jobs[mItemId] = {
            "inos"  => inos,
            "durs"  => durs,
            "title" => title,
            "done"  => have
        };
        Application.Storage.setValue(Store.SYNC_JOBS, jobs);

        WatchUi.pushView(new ErrorView(WatchUi.loadResource(Rez.Strings.queued)), new ErrorViewDelegate(), WatchUi.SLIDE_LEFT);
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
