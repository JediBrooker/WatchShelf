using Toybox.Application;
using Toybox.Graphics;
using Toybox.WatchUi;

// Entry view for both provider flows. It draws a status line and, on first show,
// either fetches the ABS library list (sync flow) or opens the downloaded-books
// menu (playback flow).
class LibraryView extends WatchUi.View {

    static const MODE_SYNC = 0;
    static const MODE_PLAYBACK = 1;

    private var mMode;
    private var mMessage;
    private var mStarted;

    function initialize(mode) {
        View.initialize();
        mMode = mode;
        mMessage = WatchUi.loadResource(Rez.Strings.loading);
        mStarted = false;
    }

    function onShow() {
        if (mStarted) {
            // Returning from a pushed menu -> nothing left to do here.
            WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
            return;
        }
        mStarted = true;

        if (!AbsApi.isConfigured()) {
            mMessage = WatchUi.loadResource(Rez.Strings.needConfig);
            WatchUi.requestUpdate();
            return;
        }

        if (mMode == MODE_PLAYBACK) {
            openDownloadedMenu();
        } else {
            AbsApi.getLibraries(method(:onLibraries));
        }
    }

    function onUpdate(dc) {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.drawText(dc.getWidth() / 2, dc.getHeight() / 2, Graphics.FONT_SMALL,
            mMessage, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // ---- sync flow: got the library list ----------------------------------
    function onLibraries(code, data) {
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
            mMessage = WatchUi.loadResource(Rez.Strings.errLibraries) + "\n(" + code + ")";
            WatchUi.requestUpdate();
        }
    }

    // ---- playback flow: manage what is already downloaded ------------------
    function openDownloadedMenu() {
        WatchUi.pushView(new DownloadedMenu(), new DownloadedMenuDelegate(), WatchUi.SLIDE_LEFT);
    }
}
