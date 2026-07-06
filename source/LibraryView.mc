using Toybox.Application;
using Toybox.Graphics;
using Toybox.WatchUi;

// Sync-configuration entry screen. On first show it fetches the ABS library list,
// then pushes a menu of libraries. It is a plain View, so WatchShelfApp pairs it
// with LibraryViewDelegate to handle Back (that missing pairing was the hang).
class LibraryView extends WatchUi.View {

    private var mMessage;
    private var mStarted;

    function initialize() {
        View.initialize();
        mMessage = WatchUi.loadResource(Rez.Strings.loading);
        mStarted = false;
    }

    function onShow() {
        // Re-shown after the user backs out of the pushed menu: do nothing.
        // (Previously this called popView from inside onShow - a re-entrant UI
        // op during a lifecycle callback, which can lock the UI thread.)
        if (mStarted) { return; }
        mStarted = true;

        if (!AbsApi.isConfigured()) {
            // Sideloaded apps can't use phone settings, so log in on the watch.
            Login.start();
            return;
        }
        AbsApi.getLibraries(method(:onLibraries));
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
            WatchUi.pushView(menu, new LibraryMenuDelegate(), WatchUi.SLIDE_LEFT);
        } else {
            mMessage = Errors.message(Rez.Strings.errLibraries, code);
            WatchUi.requestUpdate();
        }
    }
}
