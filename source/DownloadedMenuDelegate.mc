using Toybox.Application;
using Toybox.Communications;
using Toybox.Media;
using Toybox.WatchUi;

// This is a management screen. Tapping a track queues it for deletion and runs a
// sync; "Done" starts playback of the downloaded set.
class DownloadedMenuDelegate extends WatchUi.Menu2InputDelegate {

    function initialize() {
        Menu2InputDelegate.initialize();
    }

    // Tap a track = delete it (queued, then a sync performs Media.deleteCachedItem).
    function onSelect(item) {
        var refId = item.getId();

        // The "Browse library" row -> open the library (LibraryView logs in first
        // if we're not configured yet, otherwise it lists books to download).
        if ((refId instanceof Toybox.Lang.String) && refId.equals("browse")) {
            WatchUi.pushView(new LibraryView(), new LibraryViewDelegate(), WatchUi.SLIDE_LEFT);
            return;
        }

        // "Log out" -> clear the stored server/token and go straight to a fresh
        // on-watch login (switchToView, not push, so Back doesn't return to a
        // stale pre-logout menu - matches how LoginView.onLogin returns on success).
        if ((refId instanceof Toybox.Lang.String) && refId.equals("logout")) {
            AbsApi.logout();
            WatchUi.switchToView(new LoginView(), new LibraryViewDelegate(), WatchUi.SLIDE_LEFT);
            return;
        }

        var deleteList = Application.Storage.getValue(Store.DELETE_LIST);
        if (deleteList == null) { deleteList = []; }
        deleteList.add(refId);
        Application.Storage.setValue(Store.DELETE_LIST, deleteList);

        // Run a sync now to perform the deletion, then confirm.
        Communications.startSync();
        WatchUi.pushView(new ErrorView(WatchUi.loadResource(Rez.Strings.deleting)), null, WatchUi.SLIDE_LEFT);
    }

    // "Done" (menu action) = start playing the downloaded set.
    function onDone() {
        Media.startPlayback(null);
    }

    function onBack() {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
}
