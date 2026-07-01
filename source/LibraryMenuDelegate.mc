using Toybox.WatchUi;

// Picked a library -> get the lean book list from the sidecar, show all books.
class LibraryMenuDelegate extends WatchUi.Menu2InputDelegate {

    function initialize() {
        Menu2InputDelegate.initialize();
    }

    function onSelect(item) {
        AbsApi.getBookList(item.getId(), method(:onList));
    }

    function onList(code, data) {
        if ((code == 200) && (data != null) && (data["books"] != null)) {
            var books = data["books"];
            var menu = new WatchUi.Menu2({ :title => WatchUi.loadResource(Rez.Strings.pickBook) });
            for (var i = 0; i < books.size(); ++i) {
                var b = books[i];
                menu.addItem(new WatchUi.MenuItem(b["title"], b["author"], b["id"], null));
            }
            WatchUi.pushView(menu, new BookMenuDelegate(), WatchUi.SLIDE_LEFT);
        } else {
            WatchUi.pushView(new ErrorView(WatchUi.loadResource(Rez.Strings.errItems) + "\n(" + code + ")"),
                null, WatchUi.SLIDE_LEFT);
        }
    }

    function onBack() {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
}
