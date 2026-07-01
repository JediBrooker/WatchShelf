using Toybox.WatchUi;

// Picked a library -> show the browse-mode menu (all / author / series / collection).
class LibraryMenuDelegate extends WatchUi.Menu2InputDelegate {
    function initialize() { Menu2InputDelegate.initialize(); }
    function onSelect(item) { Browse.start(item.getId()); }
    function onBack() { WatchUi.popView(WatchUi.SLIDE_RIGHT); }
}
