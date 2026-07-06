using Toybox.Application;
using Toybox.Communications;
using Toybox.Media;
using Toybox.WatchUi;

// Per-book actions, reached from PlayMenu. Resume / Play from start hand the
// chosen book + mode to the native player via Media.startPlayback(args); the
// ContentIterator reads {item, mode} to position its cursor (see
// ContentIterator.applyStart). Delete queues this one book for removal, exactly
// like the old top-level book-row tap did.
class BookActionMenu extends WatchUi.Menu2 {

    function initialize(itemId, title) {
        Menu2.initialize({ :title => title });
        addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.resume), null, "resume", null));
        addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.playFromStart), null, "start", null));
        addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.deleteBook), null, "delete", null));
    }
}

class BookActionMenuDelegate extends WatchUi.Menu2InputDelegate {

    private var mItemId;

    function initialize(itemId) {
        Menu2InputDelegate.initialize();
        mItemId = itemId;
    }

    function onSelect(item) {
        var id = item.getId();

        // Resume from the synced position; Play from start begins at 0. Both pass
        // the book id + mode to the native player, which launches playback mode
        // and hands the args to our ContentDelegate/ContentIterator.
        if ((id instanceof Toybox.Lang.String) && id.equals("resume")) {
            Media.startPlayback({ "item" => mItemId, "mode" => "resume" });
            return;
        }
        if ((id instanceof Toybox.Lang.String) && id.equals("start")) {
            Media.startPlayback({ "item" => mItemId, "mode" => "start" });
            return;
        }

        // Delete this one book: queue it and run a sync (SyncDelegate.deleteQueued
        // evicts each cached chunk). Whole-book only - see Constants.mc for why
        // per-chunk state is forbidden. Pop back to the book list afterwards.
        if ((id instanceof Toybox.Lang.String) && id.equals("delete")) {
            var deleteList = Application.Storage.getValue(Store.DELETE_LIST);
            if (deleteList == null) { deleteList = []; }
            deleteList.add(mItemId);
            Application.Storage.setValue(Store.DELETE_LIST, deleteList);
            Communications.startSync();
            Notify.flash(Rez.Strings.deleting);
            WatchUi.popView(WatchUi.SLIDE_RIGHT);
            return;
        }
    }

    function onBack() {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
}
