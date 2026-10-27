using Toybox.WatchUi;

// Browse entry: All books / By author / By series / By collection. Group lists
// come from the sidecar (lean); picking one shows a filtered book list that flows
// into the normal download path (BookMenuDelegate).
//
// NO cover thumbnails in this pick-a-book list, deliberately. It is unbounded
// (a whole library - the sidecar returns up to 1000 books), the covers are not
// yet local (each would need a live makeImageRequest + JPEG decode), and this
// whole app shares the 512KB audioContentProvider ceiling. b29 tried
// IconMenuItem + a live cover loader here and it OOM'd on real libraries
// ("Media Error Occurred") - building ~1000 icon-bearing rows alone crosses
// the ceiling, before any cover even loads. Plain MenuItem is the known-good
// shape. Cover art lives where it is memory-bounded instead: DownloadedMenu
// (only books you actually downloaded, icons already in Storage) and the
// native player (Media.setAlbumArt).
module Browse {

    function start(libId, podcast) {
        var m = new WatchUi.Menu2({ :title => WatchUi.loadResource(Rez.Strings.browseLibrary) });
        m.addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.continueListening), null, "continue", null));
        m.addItem(new WatchUi.MenuItem(WatchUi.loadResource(podcast ? Rez.Strings.podcastEpisodes : Rez.Strings.allBooks), null, "all", null));
        m.addItem(new WatchUi.MenuItem(WatchUi.loadResource(podcast ? Rez.Strings.podcastShows : Rez.Strings.byAuthor), null, "authors", null));
        if (!podcast) {
            m.addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.bySeries), null, "series", null));
            m.addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.byCollection), null, "collections", null));
        }
        WatchUi.pushView(m, new BrowseDelegate(libId), WatchUi.SLIDE_LEFT);
    }

    // Build + push a book menu from { books:[{id,title,author}] }.
    function showBooks(code, data) {
        // Session expired -> re-login instead of a dead-end error.
        if (code == 401) { Login.reauth(); return; }
        if (code != 200 || data == null || data["books"] == null) {
            WatchUi.pushView(new ErrorView(Errors.message(Rez.Strings.errItems, code)),
                new ErrorViewDelegate(), WatchUi.SLIDE_LEFT);
            return;
        }
        if (data["books"].size() == 0) {
            WatchUi.pushView(new ErrorView(WatchUi.loadResource(Rez.Strings.errNone)),
                new ErrorViewDelegate(), WatchUi.SLIDE_LEFT);
            return;
        }
        var books = data["books"];
        var m = new WatchUi.Menu2({ :title => WatchUi.loadResource(Rez.Strings.pickBook) });
        // Plain MenuItem, no per-row icon: this list is O(whole library) and
        // must stay lean in the 512KB ACP heap (see module header). Nothing is
        // retained past this loop.
        for (var i = 0; i < books.size(); ++i) {
            var b = books[i];
            m.addItem(new WatchUi.MenuItem(b["title"], b["author"], b["id"], null));
        }
        WatchUi.pushView(m, new BookMenuDelegate(), WatchUi.SLIDE_LEFT);
    }
}

class BrowseDelegate extends WatchUi.Menu2InputDelegate {
    private var mLib;
    function initialize(libId) { Menu2InputDelegate.initialize(); mLib = libId; }
    function onSelect(item) {
        var mode = item.getId();
        if (mode.equals("continue")) { AbsApi.getContinueList(mLib, method(:onBooks)); }
        else if (mode.equals("all")) { AbsApi.getBookList(mLib, null, null, method(:onBooks)); }
        else if (mode.equals("authors")) { AbsApi.getAuthors(mLib, method(:onAuthors)); }
        else if (mode.equals("series")) { AbsApi.getSeries(mLib, method(:onSeries)); }
        else { AbsApi.getCollections(mLib, method(:onCollections)); }
    }
    function onBooks(code, data) { Browse.showBooks(code, data); }
    function onAuthors(code, data)     { pushGroups(code, data, "authors", "author"); }
    function onSeries(code, data)      { pushGroups(code, data, "series", "series"); }
    function onCollections(code, data) { pushGroups(code, data, "collections", "collection"); }

    function pushGroups(code, data, key, filterType) {
        if (code != 200 || data == null || data[key] == null || data[key].size() == 0) {
            WatchUi.pushView(new ErrorView(WatchUi.loadResource(Rez.Strings.errNone)), new ErrorViewDelegate(), WatchUi.SLIDE_LEFT);
            return;
        }
        var groups = data[key];
        var m = new WatchUi.Menu2({ :title => WatchUi.loadResource(Rez.Strings.browseLibrary) });
        for (var i = 0; i < groups.size(); ++i) {
            var g = groups[i];
            var podcast = (g["podcast"] == true);
            var sub = (g["count"] != null) ? (g["count"].toString() + (podcast ? " episodes" : " books")) : null;
            var identity = podcast ? { "id" => g["id"], "podcast" => true } : g["id"];
            m.addItem(new WatchUi.MenuItem(g["name"], sub, identity, null));
        }
        WatchUi.pushView(m, new GroupDelegate(mLib, filterType), WatchUi.SLIDE_LEFT);
    }
    function onBack() { WatchUi.popView(WatchUi.SLIDE_RIGHT); }
}

class GroupDelegate extends WatchUi.Menu2InputDelegate {
    private var mLib;
    private var mType;
    function initialize(libId, filterType) { Menu2InputDelegate.initialize(); mLib = libId; mType = filterType; }
    function onSelect(item) {
        var identity = item.getId();
        if ((identity instanceof Toybox.Lang.Dictionary) && (identity["podcast"] == true)) {
            var menu = new WatchUi.Menu2({ :title => item.getLabel() });
            menu.addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.podcastEpisodes), null, "episodes", null));
            menu.addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.podcastAutomatic),
                PodcastMenus.enabledLabel(PodcastSettings.get(identity["id"])["enabled"]), "automatic", null));
            WatchUi.pushView(menu, new PodcastBrowseDelegate(mLib, identity["id"], item.getLabel()), WatchUi.SLIDE_LEFT);
            return;
        }
        AbsApi.getBookList(mLib, mType, identity, method(:onBooks));
    }
    function onBooks(code, data) { Browse.showBooks(code, data); }
    function onBack() { WatchUi.popView(WatchUi.SLIDE_RIGHT); }
}

class PodcastBrowseDelegate extends WatchUi.Menu2InputDelegate {
    private var mLib;
    private var mShow;
    private var mTitle;
    function initialize(lib, show, title) {
        Menu2InputDelegate.initialize(); mLib = lib; mShow = show; mTitle = title;
    }
    function onSelect(item) {
        if (item.getId().equals("automatic")) { PodcastMenus.showSettings(mShow, mTitle); }
        else { AbsApi.getBookList(mLib, "author", mShow, method(:onBooks)); }
    }
    function onBooks(code, data) { Browse.showBooks(code, data); }
    function onBack() { WatchUi.popView(WatchUi.SLIDE_RIGHT); }
}
