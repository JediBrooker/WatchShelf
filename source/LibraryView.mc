using Toybox.Application;
using Toybox.Graphics;
using Toybox.Timer;
using Toybox.WatchUi;

// Sync-configuration entry screen. On first show it fetches the ABS library list,
// then replaces itself with a menu of libraries. It is a plain View, so
// WatchShelfApp pairs it with LibraryViewDelegate to handle Back while loading.
class LibraryView extends WatchUi.View {

    private var mMessage;
    private var mStarted;
    private var mLoginTimer;

    function initialize() {
        View.initialize();
        mMessage = WatchUi.loadResource(Rez.Strings.loading);
        mStarted = false;
        mLoginTimer = null;
    }

    function onShow() {
        // Start the request only once per view instance. A UI operation from
        // inside onShow is re-entrant and can lock the UI thread, which is why
        // the unconfigured login replacement below is deferred to a timer.
        if (mStarted) { return; }
        mStarted = true;

        if (!AbsApi.isConfigured()) {
            // Sideloaded apps can't use phone settings, so log in on the watch.
            // Defer the replacement: switchToView pops this loading view, and a
            // pop from inside onShow is a re-entrant UI operation that can lock
            // the UI thread on real devices.
            mLoginTimer = new Timer.Timer();
            mLoginTimer.start(method(:openLogin), 100, false);
            return;
        }
        AbsApi.getLibraries(method(:onLibraries));
    }

    function openLogin() {
        mLoginTimer = null;
        Login.start();
    }

    function onHide() {
        // If the view is interrupted before the deferred replacement fires,
        // retry cleanly when it is next shown instead of leaving Loading stuck.
        if (mLoginTimer != null) {
            mLoginTimer.stop();
            mLoginTimer = null;
            mStarted = false;
        }
    }

    function onUpdate(dc) {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.drawText(dc.getWidth() / 2, dc.getHeight() / 2, Graphics.FONT_SMALL,
            mMessage, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // Got the library list -> show a menu of book libraries.
    function onLibraries(code, data) {
        // Session expired -> re-login instead of a dead-end error.
        if (code == 401) { Login.reauth(); return; }
        if ((code == 200) && (data != null) && (data["libraries"] != null)) {
            var libs = data["libraries"];
            var menu = new WatchUi.Menu2({ :title => WatchUi.loadResource(Rez.Strings.pickLibrary) });
            for (var i = 0; i < libs.size(); ++i) {
                var lib = libs[i];
                // Only book libraries are audiobooks; skip podcast libraries.
                if (lib["mediaType"] != null && lib["mediaType"].equals("book")) {
                    menu.addItem(new WatchUi.MenuItem(lib["name"], null, lib["id"], null));
                }
            }
            // Replace the transient loading screen so Back returns in one press
            // instead of first revealing a stale "Loading..." view.
            WatchUi.switchToView(menu, new LibraryMenuDelegate(), WatchUi.SLIDE_LEFT);
        } else {
            mMessage = Errors.message(Rez.Strings.errLibraries, code);
            WatchUi.requestUpdate();
        }
    }
}
