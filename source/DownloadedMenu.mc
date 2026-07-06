using Toybox.Application;
using Toybox.Media;
using Toybox.WatchUi;

// The top-level management screen: browse the library, open the downloaded
// books ("Play downloaded" -> PlayMenu, where each book offers Resume / Play
// from start / Delete), sync, log out, and bulk maintenance. The per-book list
// lives in PlayMenu now, not here. The watch's own Music widget (hold the
// music-controls button -> Music Providers -> WatchShelf) reaches the SAME
// downloaded content and is the platform-standard way into playback too.
class DownloadedMenu extends WatchUi.Menu2 {

    function initialize() {
        Menu2.initialize({ :title => titleWithSize() });

        // This "Downloaded" screen is where the audio provider first opens, so it
        // MUST lead to the books. Always show a way into the library; LibraryView
        // logs the user in first if they aren't configured yet.
        addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.browseLibrary), null, "browse", null));

        var index = Application.Storage.getValue(Store.BOOK_INDEX);
        if (index == null) { index = []; }

        // "Play downloaded" -> the book list (PlayMenu), where each book offers
        // Resume / Play from start / Delete. A normal tap handled in onSelect;
        // NOT Menu2's onDone() (that only fires on a CheckboxMenu, never a plain
        // Menu2, so it would be unreachable on real hardware).
        if (index.size() > 0) {
            addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.playDownloaded), null, "play", null));
        }

        // "Sync now" - force an on-demand two-way progress exchange with ABS
        // (push our listens, pull other devices'). The value at a device handoff:
        // the OS only auto-syncs on its own schedule (roughly, on the charger),
        // which won't have fired in the minute between finishing on the watch and
        // picking up in the car - and there is no wake-on-reconnect event to make
        // it instant. This is the deterministic "sync before I switch" control.
        if (AbsApi.isConfigured() && (index.size() > 0)) {
            addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.syncNow), null, "syncnow", null));
        }

        // Only offer to log out if actually logged in - avoids a pointless item
        // on a fresh, unconfigured install.
        if (AbsApi.isConfigured()) {
            addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.logOut), null, "logout", null));
        }

        // A crashed/interrupted sync can leave queued jobs behind, which then
        // get reprocessed on every future sync alongside anything new. Offer a
        // way to wipe just the pending queue - sideloaded apps can't be cleanly
        // uninstalled to reset this, so it has to be reachable from in here.
        if (hasQueued()) {
            addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.clearQueue), null, "clearqueue", null));
        }

        if (index.size() > 0) {
            addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.deleteAllDownloads), null, "deleteall", null));
        }
        // Individual books now live under "Play downloaded" (PlayMenu), each with
        // its own Resume / Play from start / Delete actions - not as rows here.
    }

    function hasQueued() {
        var deleteList = Application.Storage.getValue(Store.DELETE_LIST);
        return (JobStore.list().size() > 0)
            || ((deleteList != null) && (deleteList.size() > 0));
    }

    // Show used cache space in the menu title. CacheStatistics exposes `size`
    // (current bytes) and `capacity` (total bytes) - both Lang.Long. There is no
    // `used` field.
    function titleWithSize() {
        var stats = Media.getCacheStatistics();
        var used = 0;
        if (stats != null && stats.size != null) { used = stats.size; }
        var mb = (used / (1024 * 1024)).toNumber();
        return WatchUi.loadResource(Rez.Strings.downloaded) + " " + Versions.tag + " (" + mb + " MB)";
    }
}
