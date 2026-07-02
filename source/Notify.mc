using Toybox.WatchUi;

// Transient status feedback ("Queued", "Removing", "Queue cleared"). A toast
// self-dismisses, so the user is never left staring at a stuck status screen
// waiting on a Back press (the old pushView pattern sat there indefinitely
// after the sync finished - a reported complaint). Falls back to the old
// ErrorView push on firmware without showToast.
module Notify {
    function flash(stringRezId) {
        if (WatchUi has :showToast) {
            WatchUi.showToast(stringRezId, null);
        } else {
            WatchUi.pushView(new ErrorView(WatchUi.loadResource(stringRezId)),
                new ErrorViewDelegate(), WatchUi.SLIDE_LEFT);
        }
    }
}
