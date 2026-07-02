using Toybox.Application;
using Toybox.Media;
using Toybox.WatchUi;

// Lists downloaded books (grouped from their individual chunk tracks - a book is
// ~3-min chunks, so a long audiobook can be 100+ tracks; showing each one
// individually would make this screen unusable). Selecting a book removes ALL of
// its chunks; "Play downloaded" starts playback (Media.startPlayback), which
// hands off to the native player driving ContentIterator's set. The watch's own
// Music widget (hold the music-controls button -> Music Providers -> WatchShelf)
// reaches the SAME downloaded content and is the platform-standard way in too.
class DownloadedMenu extends WatchUi.Menu2 {

    function initialize() {
        Menu2.initialize({ :title => titleWithSize() });

        // This "Downloaded" screen is where the audio provider first opens, so it
        // MUST lead to the books. Always show a way into the library; LibraryView
        // logs the user in first if they aren't configured yet.
        addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.browseLibrary), null, "browse", null));

        var books = groupedBooks();
        var itemIds = books.keys();

        // Explicit, direct "Play" action - a plain MenuItem calling
        // Media.startPlayback() straight from onSelect. NOT wired through
        // Menu2's onDone(): per Garmin's own API docs, onDone() is only ever
        // triggered by a WatchUi.CheckboxMenu, never a plain Menu2 like this
        // one - so a Done-based "play" action here would be silently
        // unreachable on real hardware no matter what the user pressed.
        if (itemIds.size() > 0) {
            addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.playDownloaded), null, "play", null));
        }

        // Only offer to log out if actually logged in - avoids a pointless item
        // on a fresh, unconfigured install.
        if (AbsApi.isConfigured()) {
            addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.logOut), null, "logout", null));
        }

        // A crashed/interrupted sync can leave queued entries behind (they're
        // only cleared as each one finishes downloading), which then get
        // reprocessed on every future sync alongside anything new. Offer a way
        // to wipe just the pending queue - sideloaded apps can't be cleanly
        // uninstalled to reset this, so it has to be reachable from in here.
        if (hasQueued()) {
            addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.clearQueue), null, "clearqueue", null));
        }

        if (itemIds.size() > 0) {
            addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.deleteAllDownloads), null, "deleteall", null));
        }

        for (var i = 0; i < itemIds.size(); ++i) {
            var itemId = itemIds[i];
            var book = books[itemId];
            var sub = book["count"].toString() + " part" + ((book["count"] == 1) ? "" : "s");
            addItem(new WatchUi.MenuItem(book["title"], sub, itemId, null));
        }
    }

    function hasQueued() {
        var syncList = Application.Storage.getValue(Store.SYNC_LIST);
        var deleteList = Application.Storage.getValue(Store.DELETE_LIST);
        return ((syncList != null) && (syncList.size() > 0))
            || ((deleteList != null) && (deleteList.size() > 0));
    }

    // { itemId => { "title" => bookTitle, "count" => Number } } - one entry per
    // book, folding every chunk that shares the same TrackInfo.ITEM_ID together.
    function groupedBooks() {
        var tracks = Application.Storage.getValue(Store.TRACKS);
        if (tracks == null) { tracks = {}; }

        var books = {};
        var refIds = tracks.keys();
        for (var i = 0; i < refIds.size(); ++i) {
            var info = tracks[refIds[i]];
            var itemId = info[TrackInfo.ITEM_ID];
            if (itemId == null) { itemId = "unknown"; }

            var book = books[itemId];
            if (book == null) {
                book = { "title" => bookTitle(refIds[i], info), "count" => 0 };
                books[itemId] = book;
            }
            book["count"] = book["count"] + 1;
        }
        return books;
    }

    // Prefer the cached media's own metadata title (whole-file, no chunk suffix);
    // fall back to stored BOOK_TITLE, then the per-chunk TITLE, then "Book".
    function bookTitle(refId, info) {
        var ref = new Media.ContentRef(refId, Media.CONTENT_TYPE_AUDIO);
        var obj = Media.getCachedContentObj(ref);
        if (obj != null && obj.getMetadata() != null && obj.getMetadata().title != null) {
            return obj.getMetadata().title;
        }
        if (info[TrackInfo.BOOK_TITLE] != null) { return info[TrackInfo.BOOK_TITLE]; }
        if (info[TrackInfo.TITLE] != null) { return info[TrackInfo.TITLE]; }
        return "Book";
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
