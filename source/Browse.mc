using Toybox.Communications;
using Toybox.WatchUi;

// Browse entry: All books / By author / By series / By collection. Group lists
// come from the sidecar (lean); picking one shows a filtered book list that flows
// into the normal download path (BookMenuDelegate).
module Browse {

    // Lazy cover thumbnails in the pick-a-book list are capped: each 48px
    // bitmap is ~4.6KB worst case, browse lists can be hundreds of books, and
    // everything shares the 512KB audioContentProvider ceiling. Rows past the
    // cap keep the placeholder glyph.
    const COVER_MAX = 20;

    // Generation counter for CoverLoader chains. Each new book list bumps it;
    // a loader whose generation is stale stops at its next callback and drops
    // its menu references. Without this, every abandoned book list would stay
    // pinned in memory (items + fetched bitmaps) until its 20-request chain
    // ran dry - stacking a few browses could approach the 512KB ceiling.
    var gCoverGen = 0;
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
        // IconMenuItem (not MenuItem) so the cover actually renders in the
        // list on round watches; rows start with the placeholder glyph and a
        // CoverLoader swaps real covers in one at a time as they arrive.
        var placeholder = WatchUi.loadResource(Rez.Drawables.bookIcon);
        var items = [];
        var ids = [];
        for (var i = 0; i < books.size(); ++i) {
            var b = books[i];
            var it = new WatchUi.IconMenuItem(b["title"], b["author"], b["id"], placeholder, null);
            m.addItem(it);
            items.add(it);
            ids.add(b["id"]);
        }
        WatchUi.pushView(m, new BookMenuDelegate(), WatchUi.SLIDE_LEFT);
        Browse.gCoverGen += 1;
        new CoverLoader(items, ids, Browse.gCoverGen).start();
    }
}

// Fetches cover thumbnails for a pushed book menu SEQUENTIALLY - one
// makeImageRequest at a time, the next fired from the previous one's
// callback. Parallel-firing dozens of image requests overruns the bluetooth
// request queue and gets requests dropped; a chain also stops costing
// anything the moment it finishes. The loader stays alive because the
// in-flight request holds its callback Method; when a NEWER book list starts
// its own loader (Browse.gCoverGen moves on), this one stops at its next
// callback and releases the abandoned menu.
class CoverLoader {

    private var mItems; // [ IconMenuItem, ... ]
    private var mIds;   // [ itemId, ... ] parallel
    private var mPos;
    private var mGen;   // Browse.gCoverGen at creation

    function initialize(items, ids, gen) {
        mItems = items;
        mIds = ids;
        mPos = 0;
        mGen = gen;
    }

    function start() {
        fetchNext();
    }

    function fetchNext() {
        if ((mGen != Browse.gCoverGen)
            || (mPos >= mIds.size()) || (mPos >= Browse.COVER_MAX)) {
            mItems = null;
            mIds = [];
            return;
        }
        Communications.makeImageRequest(
            AbsApi.coverUrl(mIds[mPos], BookStore.ICON_PX), null,
            { :maxWidth => BookStore.ICON_PX, :maxHeight => BookStore.ICON_PX },
            method(:onCover));
    }

    function onCover(code, data) {
        if (mGen != Browse.gCoverGen) {
            mItems = null;
            mIds = [];
            return;
        }
        if ((code == 200) && (data != null)) {
            mItems[mPos].setIcon(data);
            WatchUi.requestUpdate();
        }
        mPos += 1;
        fetchNext();
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
