using Toybox.Application;
using Toybox.WatchUi;

// Picked a library -> load its items and show the book menu.
class LibraryMenuDelegate extends WatchUi.Menu2InputDelegate {

    function initialize() {
        Menu2InputDelegate.initialize();
    }

    function onSelect(item) {
        var libraryId = item.getId();
        AbsApi.getItems(libraryId, method(:onItems));
    }

    function onItems(code, data) {
        if ((code == 200) && (data != null) && (data["results"] != null)) {
            var results = data["results"];
            var menu = new WatchUi.Menu2({ :title => WatchUi.loadResource(Rez.Strings.pickBook) });
            for (var i = 0; i < results.size(); ++i) {
                var it = results[i];
                var media = it["media"];
                var title = "?";
                var sub = null;
                if (media != null && media["metadata"] != null) {
                    title = media["metadata"]["title"];
                    sub = media["metadata"]["authorName"];
                }
                menu.addItem(new WatchUi.MenuItem(title, sub, it["id"], null));
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
