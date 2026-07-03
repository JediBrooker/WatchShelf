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

        // "Sync now" -> force a one-shot sync so the two-way progress exchange
        // runs even with no download/delete queued. The FORCE_SYNC flag makes
        // isSyncNeeded() true (onStartSync clears it), and startSync() kicks the
        // system sync that carries it out. Whether it can actually reach ABS
        // depends on connectivity right now (phone in range / WiFi) - the same
        // constraint every sidecar call has.
        if ((id instanceof Toybox.Lang.String) && id.equals("syncnow")) {
            Application.Storage.setValue(Store.FORCE_SYNC, true);
            Communications.startSync();
            Notify.flash(Rez.Strings.syncing);
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
        // can leave queued jobs behind, since they're only cleared as each book
        // finishes) WITHOUT starting a sync - we want to drop them, not process
        // them. Cover art is fetched at job start, so a job cleared before its
        // first chunk landed has art keys no other path would ever reclaim.
        if ((id instanceof Toybox.Lang.String) && id.equals("clearqueue")) {
            var jobIds = JobStore.list();
            JobStore.clearAll();
            for (var i = 0; i < jobIds.size(); ++i) {
                BookStore.dropArtIfUnindexed(jobIds[i]);
            }
            Application.Storage.setValue(Store.DELETE_LIST, []);
            Notify.flash(Rez.Strings.queueCleared);
            return;
        }

        // "Delete all downloads" -> queue every downloaded book.
        if ((id instanceof Toybox.Lang.String) && id.equals("deleteall")) {
            var index = Application.Storage.getValue(Store.BOOK_INDEX);
            if (index == null) { index = []; }
            queueDelete(index);
            return;
        }

        // Anything else is a BOOK's itemId - queue that one book for deletion.
        // Deletions are always whole-book (a book can be 100+ ~3-min chunks;
        // per-chunk anything isn't usable, and per-chunk STORAGE is what used
        // to OOM-crash the app - see Constants.mc).
        queueDelete([id]);
    }

    // Add every given book itemId to the delete queue, then run a sync now to
    // perform the deletions (Media.deleteCachedItem happens per cached chunk in
    // SyncDelegate.deleteQueued).
    function queueDelete(itemIds) {
        if (itemIds.size() == 0) { return; }

        var deleteList = Application.Storage.getValue(Store.DELETE_LIST);
        if (deleteList == null) { deleteList = []; }
        for (var i = 0; i < itemIds.size(); ++i) {
            deleteList.add(itemIds[i]);
        }
        Application.Storage.setValue(Store.DELETE_LIST, deleteList);

        Communications.startSync();
        Notify.flash(Rez.Strings.deleting);
    }

    function onBack() {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
}
