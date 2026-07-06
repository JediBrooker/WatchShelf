using Toybox.Application;
using Toybox.WatchUi;

// "Play downloaded" -> a list of the downloaded books (one row per BOOK_INDEX
// entry, cover art if present else the placeholder glyph). Selecting a book
// opens its action menu (Resume / Play from start / Delete). This is the play
// entry point; the old top-level menu no longer plays or lists books directly.
class PlayMenu extends WatchUi.Menu2 {

    function initialize() {
        Menu2.initialize({ :title => WatchUi.loadResource(Rez.Strings.playDownloaded) });

        var index = Application.Storage.getValue(Store.BOOK_INDEX);
        if (index == null) { index = []; }

        var placeholder = WatchUi.loadResource(Rez.Drawables.bookIcon);
        for (var i = 0; i < index.size(); ++i) {
            var itemId = index[i];
            var meta = BookStore.get(itemId);
            var title = ((meta != null) && (meta["title"] != null)) ? meta["title"] : "Book";
            var count = BookStore.count(itemId);
            var sub = count.toString() + " part" + ((count == 1) ? "" : "s");
            var art = BookStore.icon(itemId);
            addItem(new WatchUi.IconMenuItem(title, sub, itemId,
                (art != null) ? art : placeholder, null));
        }
    }
}

class PlayMenuDelegate extends WatchUi.Menu2InputDelegate {
    function initialize() {
        Menu2InputDelegate.initialize();
    }

    // A book row -> its per-book action menu. The row id IS the itemId.
    function onSelect(item) {
        var itemId = item.getId();
        var meta = BookStore.get(itemId);
        var title = ((meta != null) && (meta["title"] != null)) ? meta["title"] : "Book";
        WatchUi.pushView(new BookActionMenu(itemId, title),
            new BookActionMenuDelegate(itemId), WatchUi.SLIDE_LEFT);
    }

    function onBack() {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
}
