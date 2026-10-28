using Toybox.WatchUi;

// Picked a library -> show the browse-mode menu (all / author / series / collection).
class LibraryMenuDelegate extends WatchUi.Menu2InputDelegate {
    function initialize() { Menu2InputDelegate.initialize(); }
    function onSelect(item) {
        var identity = item.getId();
        Browse.start(identity["id"], identity["podcast"] == true);
    }
    function onBack() { WatchUi.popView(WatchUi.SLIDE_RIGHT); }
}
