using Toybox.Application;
using Toybox.WatchUi;

// "Play downloaded" -> a list of the downloaded books (one row per BOOK_INDEX
// entry). Selecting a book opens its action menu (Resume / Play from start /
// Delete). This is the play entry point; the old top-level menu no longer plays
// or lists books directly.
//
// PLAIN MenuItem, NO per-row cover art - deliberately. An earlier b34 draft used
// IconMenuItem with BookStore.icon(); that art is dead code today (cover fetch
// was removed in b33, so icon() always returns null and only the placeholder
// glyph rendered), so the IconMenuItem bought nothing while nudging toward the
// per-row-icon pattern the Browse list had to abandon (b29->b30) to stop OOMing
// its unbounded list. Keep this list plain; cover art belongs only on the player
// screen (Media.setAlbumArt), never as menu-row icons.
class PlayMenu extends WatchUi.Menu2 {

    function initialize() {
        Menu2.initialize({ :title => WatchUi.loadResource(Rez.Strings.playDownloaded) });

        var index = Application.Storage.getValue(Store.BOOK_INDEX);
        if (index == null) { index = []; }

        for (var i = 0; i < index.size(); ++i) {
            var itemId = index[i];
            var count = BookStore.count(itemId);
            // Skip a book with no cached chunks - an unplayable transient (the
            // crash window between a delete's un-index and evict). Selecting it
            // would have nothing to play and could start a different book.
            if (count == 0) { continue; }
            var meta = BookStore.get(itemId);
            var title = ((meta != null) && (meta["title"] != null)) ? meta["title"] : "Book";
            var sub;
            if ((meta != null) && (meta["durs"] != null)) {
                // Percentage of the suffix intentionally selected for this
                // watch. Already-listened head chunks are omitted, so a fully
                // cached tail is 100% synced rather than (say) 40% of the whole
                // book. Legacy records default first() to 0 and retain ordinary
                // full-book percentage semantics.
                var needed = Chunks.total(meta["durs"]) - BookStore.first(itemId);
                if (needed > 0) {
                    var pct = ((count * 100) / needed.toFloat()).toNumber();
                    if ((count > 0) && (pct < 1)) { pct = 1; }
                    if (pct > 100) { pct = 100; }
                    sub = pct.toString() + "% " + WatchUi.loadResource(Rez.Strings.synced);
                }
            }
            // Corrupt/pre-duration legacy metadata should stay visible rather
            // than crashing the whole menu; retain the old count fallback.
            if (sub == null) {
                sub = count.toString() + " part" + ((count == 1) ? "" : "s");
            }
            addItem(new WatchUi.MenuItem(title, sub, itemId, null));
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
