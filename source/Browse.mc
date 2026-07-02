using Toybox.WatchUi;

// Browse entry: All books / By author / By series / By collection. Group lists
// come from the sidecar (lean); picking one shows a filtered book list that flows
// into the normal download path (BookMenuDelegate).
module Browse {
    function start(libId) {
        var m = new WatchUi.Menu2({ :title => WatchUi.loadResource(Rez.Strings.browseLibrary) });
        m.addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.allBooks), null, "all", null));
        m.addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.byAuthor), null, "authors", null));
        m.addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.bySeries), null, "series", null));
        m.addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.byCollection), null, "collections", null));
        WatchUi.pushView(m, new BrowseDelegate(libId), WatchUi.SLIDE_LEFT);
    }

    // Build + push a book menu from { books:[{id,title,author}] }.
    function showBooks(code, data) {
        if (code != 200 || data == null || data["books"] == null || data["books"].size() == 0) {
            WatchUi.pushView(new ErrorView(WatchUi.loadResource(Rez.Strings.errItems) + "\n(" + code + ")"),
                new ErrorViewDelegate(), WatchUi.SLIDE_LEFT);
            return;
        }
        var books = data["books"];
        var m = new WatchUi.Menu2({ :title => WatchUi.loadResource(Rez.Strings.pickBook) });
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
        if (mode.equals("all")) { AbsApi.getBookList(mLib, null, null, method(:onBooks)); }
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
            var sub = (g["count"] != null) ? (g["count"].toString() + " books") : null;
            m.addItem(new WatchUi.MenuItem(g["name"], sub, g["id"], null));
        }
        WatchUi.pushView(m, new GroupDelegate(mLib, filterType), WatchUi.SLIDE_LEFT);
    }
    function onBack() { WatchUi.popView(WatchUi.SLIDE_RIGHT); }
}

class GroupDelegate extends WatchUi.Menu2InputDelegate {
    private var mLib;
    private var mType;
    function initialize(libId, filterType) { Menu2InputDelegate.initialize(); mLib = libId; mType = filterType; }
    function onSelect(item) { AbsApi.getBookList(mLib, mType, item.getId(), method(:onBooks)); }
    function onBooks(code, data) { Browse.showBooks(code, data); }
    function onBack() { WatchUi.popView(WatchUi.SLIDE_RIGHT); }
}
