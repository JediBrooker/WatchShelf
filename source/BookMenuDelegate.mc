using Toybox.Application;
using Toybox.Communications;
using Toybox.WatchUi;

// Picked a book -> get its lean file list from the sidecar, store ONE small
// per-book job (file inos + durations + title + resume cursor) via JobStore,
// and run a background sync. Chunk boundaries are derived by the Chunks
// module at download time - never stored per-chunk (see Constants.mc for the
// OOM post-mortem that forced this). Everything goes through the sidecar
// because most books here are single 200MB-1GB files the watch cannot
// download whole.
class BookFilesListener {
    private var mOwner;
    private var mItemId;
    private var mSpeed;

    function initialize(owner, itemId, speed) {
        mOwner = owner;
        mItemId = itemId;
        mSpeed = speed;
    }

    function onResponse(code, data) {
        // Carry the selected id with this specific request. A second rapid tap
        // can start another /files request before this one returns; using one
        // mutable delegate field would then queue the first book's file list
        // under the second book's id and make every transcode fail.
        mOwner.onFiles(mItemId, mSpeed, code, data);
    }
}

class BookSpeedMenu extends WatchUi.Menu2 {
    function initialize(title) {
        Menu2.initialize({ :title => title });
        addItem(new WatchUi.MenuItem("1.0x", null, "100", null));
        addItem(new WatchUi.MenuItem("1.25x", null, "125", null));
        addItem(new WatchUi.MenuItem("1.5x", null, "150", null));
        addItem(new WatchUi.MenuItem("1.75x", null, "175", null));
        addItem(new WatchUi.MenuItem("2.0x", null, "200", null));
    }
}

class BookSpeedMenuDelegate extends WatchUi.Menu2InputDelegate {
    private var mOwner;
    private var mItemId;

    function initialize(owner, itemId) {
        Menu2InputDelegate.initialize();
        mOwner = owner;
        mItemId = itemId;
    }

    function onSelect(item) {
        var speed = item.getId().toNumber();
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
        mOwner.downloadAtSpeed(mItemId, PlaybackSpeed.normalize(speed));
    }

    function onBack() {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
}

class BookMenuDelegate extends WatchUi.Menu2InputDelegate {

    function initialize() {
        Menu2InputDelegate.initialize();
    }

    function onSelect(item) {
        var itemId = item.getId();
        WatchUi.pushView(new BookSpeedMenu(WatchUi.loadResource(Rez.Strings.chooseSpeed)),
            new BookSpeedMenuDelegate(self, itemId), WatchUi.SLIDE_LEFT);
    }

    function downloadAtSpeed(itemId, speed) {
        PodcastSettings.adopt(itemId);
        var listener = new BookFilesListener(self, itemId, speed);
        AbsApi.getFiles(itemId, listener.method(:onResponse));
    }

    function onFiles(itemId, speed, code, data) {
        // Session expired -> re-login instead of a dead-end error.
        if (code == 401) { Login.reauth(); return; }
        if (code != 200 || data == null) {
            WatchUi.pushView(new ErrorView(Errors.message(Rez.Strings.errDetail, code)),
                new ErrorViewDelegate(), WatchUi.SLIDE_LEFT);
            return;
        }

        var error = Downloads.queue(itemId, speed, data, false);
        if (error != null) {
            WatchUi.pushView(new ErrorView(WatchUi.loadResource(error)),
                new ErrorViewDelegate(), WatchUi.SLIDE_LEFT);
            return;
        }
        Notify.flash(Rez.Strings.queued);
        Communications.startSync();
    }

    // Keep these delegates for existing callers/tests; both manual and
    // automatic queues now use the same non-UI validation and accounting.
    function plannedChunks(excludeId) { return Downloads.plannedChunks(excludeId); }
    function containsId(arr, itemId) { return Downloads.containsId(arr, itemId); }
    function inBookIndex(itemId) { return Downloads.inBookIndex(itemId); }
    function numOr(value, fallback) { return Downloads.numOr(value, fallback); }

    function onBack() {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
}
