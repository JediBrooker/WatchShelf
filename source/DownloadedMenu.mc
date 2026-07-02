using Toybox.Application;
using Toybox.Media;
using Toybox.WatchUi;

// Lists downloaded books - one row per book from the BOOK_INDEX, with the
// chunk count as the subtitle. Selecting a book removes ALL of its chunks;
// "Play downloaded" starts playback (Media.startPlayback), which hands off to
// the native player driving ContentIterator's set. The watch's own Music
// widget (hold the music-controls button -> Music Providers -> WatchShelf)
// reaches the SAME downloaded content and is the platform-standard way in too.
class DownloadedMenu extends WatchUi.Menu2 {

    function initialize() {
        Menu2.initialize({ :title => titleWithSize() });

        // This "Downloaded" screen is where the audio provider first opens, so it
        // MUST lead to the books. Always show a way into the library; LibraryView
        // logs the user in first if they aren't configured yet.
        addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.browseLibrary), null, "browse", null));

        var index = Application.Storage.getValue(Store.BOOK_INDEX);
        if (index == null) { index = []; }

        // Explicit, direct "Play" action - a plain MenuItem calling
        // Media.startPlayback() straight from onSelect. NOT wired through
        // Menu2's onDone(): per Garmin's own API docs, onDone() is only ever
        // triggered by a WatchUi.CheckboxMenu, never a plain Menu2 like this
        // one - so a Done-based "play" action here would be silently
        // unreachable on real hardware no matter what the user pressed.
        if (index.size() > 0) {
            addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.playDownloaded), null, "play", null));
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

        for (var i = 0; i < index.size(); ++i) {
            var itemId = index[i];
            var meta = BookStore.get(itemId);
            var title = ((meta != null) && (meta["title"] != null)) ? meta["title"] : "Book";
            var count = BookStore.count(itemId);
            var sub = count.toString() + " part" + ((count == 1) ? "" : "s");
            addItem(new WatchUi.MenuItem(title, sub, itemId, null));
        }
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
