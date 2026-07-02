using Toybox.Application;
using Toybox.Communications;
using Toybox.Media;
using Toybox.WatchUi;

// This is a management screen. Tapping a book queues ALL of its chunks for
// deletion and runs a sync; "Play downloaded" starts playback directly (see
// the note on that branch below for why this isn't wired through Menu2's
// onDone() the way Garmin's own MonkeyMusic sample does it).
class DownloadedMenuDelegate extends WatchUi.Menu2InputDelegate {

    function initialize() {
        Menu2InputDelegate.initialize();
    }

    function onSelect(item) {
        var id = item.getId();

        // The "Browse library" row -> open the library (LibraryView logs in first
        // if we're not configured yet, otherwise it lists books to download).
        if ((id instanceof Toybox.Lang.String) && id.equals("browse")) {
            WatchUi.pushView(new LibraryView(), new LibraryViewDelegate(), WatchUi.SLIDE_LEFT);
            return;
        }

        // "Play downloaded" -> start playback directly. NOT wired through
        // Menu2's onDone() (see class comment) - onDone() never fires on a
        // plain Menu2 like this one, only on a WatchUi.CheckboxMenu, so a
        // Done-triggered "play" was unreachable on real hardware no matter
        // what the user pressed. This is a normal, always-reachable tap.
        if ((id instanceof Toybox.Lang.String) && id.equals("play")) {
            Media.startPlayback(null);
            return;
        }

        // "Log out" -> clear the stored server/token and go straight to a fresh
        // on-watch login (switchToView, not push, so Back doesn't return to a
        // stale pre-logout menu - matches how LoginView.onLogin returns on success).
        if ((id instanceof Toybox.Lang.String) && id.equals("logout")) {
            AbsApi.logout();
            WatchUi.switchToView(new LoginView(), new LibraryViewDelegate(), WatchUi.SLIDE_LEFT);
            return;
        }

        // "Clear queue" -> abandon anything pending (a crashed/interrupted sync
        // can leave entries behind, since they're only cleared as each finishes)
        // WITHOUT starting a sync - we want to drop them, not process them.
        if ((id instanceof Toybox.Lang.String) && id.equals("clearqueue")) {
            Application.Storage.setValue(Store.SYNC_LIST, {});
            Application.Storage.setValue(Store.DELETE_LIST, []);
            WatchUi.pushView(new ErrorView(WatchUi.loadResource(Rez.Strings.queueCleared)), new ErrorViewDelegate(), WatchUi.SLIDE_LEFT);
            return;
        }

        // "Delete all downloads" -> queue every downloaded chunk, across every book.
        if ((id instanceof Toybox.Lang.String) && id.equals("deleteall")) {
            var tracks = Application.Storage.getValue(Store.TRACKS);
            if (tracks == null) { tracks = {}; }
            queueDelete(tracks.keys());
            return;
        }

        // Anything else is a BOOK's itemId (DownloadedMenu now groups chunks by
        // book, not one row per chunk - a book can be 100+ ~3-min chunks, so
        // showing/deleting them individually isn't usable). Find every
        // downloaded refId that belongs to this book and queue them all.
        var tracks = Application.Storage.getValue(Store.TRACKS);
        if (tracks == null) { tracks = {}; }
        var refIds = tracks.keys();
        var toDelete = [];
        for (var i = 0; i < refIds.size(); ++i) {
            var info = tracks[refIds[i]];
            if ((info != null) && (info[TrackInfo.ITEM_ID] != null) && info[TrackInfo.ITEM_ID].equals(id)) {
                toDelete.add(refIds[i]);
            }
        }
        queueDelete(toDelete);
    }

    // Add every given refId to the delete queue, then run a sync now to perform
    // the deletions (Media.deleteCachedItem happens in SyncDelegate.deleteQueued).
    function queueDelete(refIds) {
        if (refIds.size() == 0) { return; }

        var deleteList = Application.Storage.getValue(Store.DELETE_LIST);
        if (deleteList == null) { deleteList = []; }
        for (var i = 0; i < refIds.size(); ++i) {
            deleteList.add(refIds[i]);
        }
        Application.Storage.setValue(Store.DELETE_LIST, deleteList);

        Communications.startSync();
        WatchUi.pushView(new ErrorView(WatchUi.loadResource(Rez.Strings.deleting)), new ErrorViewDelegate(), WatchUi.SLIDE_LEFT);
    }

    function onBack() {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
}
