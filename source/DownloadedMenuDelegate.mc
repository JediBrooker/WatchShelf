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

        // "Play downloaded" -> the book list (PlayMenu). Picking a book there
        // offers Resume / Play from start / Delete. A normal, always-reachable
        // tap (NOT Menu2 onDone(), which never fires on a plain Menu2).
        if ((id instanceof Toybox.Lang.String) && id.equals("play")) {
            WatchUi.pushView(new PlayMenu(), new PlayMenuDelegate(), WatchUi.SLIDE_LEFT);
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

        // "Delete all downloads" -> wipes EVERY book, so confirm first (a mis-tap
        // here used to nuke the whole library instantly). The actual delete runs
        // from the confirmation delegate on YES.
        if ((id instanceof Toybox.Lang.String) && id.equals("deleteall")) {
            var index = Application.Storage.getValue(Store.BOOK_INDEX);
            if (index == null) { index = []; }
            if (index.size() == 0) { return; }
            WatchUi.pushView(
                new WatchUi.Confirmation(WatchUi.loadResource(Rez.Strings.confirmDeleteAll)),
                new DeleteAllConfirmDelegate(index), WatchUi.SLIDE_LEFT);
            return;
        }
        // No book rows live in this menu anymore - per-book delete moved to
        // PlayMenu -> BookActionMenu. Unknown ids fall through to nothing.
    }

    function onBack() {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
}

// "Delete all downloads" confirmation. Only on YES do we queue every book for
// deletion (Downloads.queueDelete kicks the sync that evicts the chunks).
class DeleteAllConfirmDelegate extends WatchUi.ConfirmationDelegate {
    private var mItemIds;
    function initialize(itemIds) {
        ConfirmationDelegate.initialize();
        mItemIds = itemIds;
    }
    function onResponse(response) {
        if (response == WatchUi.CONFIRM_YES) {
            Downloads.queueDelete(mItemIds);
        }
        return true;
    }
}
