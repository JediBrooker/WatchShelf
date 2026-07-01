using Toybox.WatchUi;

// Back handler for LibraryView. LibraryView is a plain WatchUi.View (a loading
// screen), so without a paired input delegate the Back button has no handler and
// the configuration view hangs instead of dismissing. This provides it.
class LibraryViewDelegate extends WatchUi.BehaviorDelegate {

    function initialize() {
        BehaviorDelegate.initialize();
    }

    // Pop the loading screen -> exits the sync-configuration flow.
    function onBack() {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
        return true;
    }
}
