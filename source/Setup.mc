using Toybox.WatchUi;

// First-run choice: type the setup on the watch, or enter it on the phone.
//
// Why this screen exists: entering a sidecar URL, username and password on the
// character wheel costs around 359 button presses (the URL alone is ~190).
// Garmin Connect settings avoid ALL of it - AbsApi.serverUrl() already falls
// back to the absServerUrl property and authToken() to absApiKey, so setting
// both there satisfies isConfigured() and the watch never asks for anything.
// That path has worked all along and nothing pointed at it; LibraryView went
// straight into the wheel.
//
// It is offered as a CHOICE rather than advice because phone settings only
// exist for a Connect IQ Store install - a sideloaded app has none, and there
// is no reliable way for the app to tell which it is. Telling a sideloader to
// "use Garmin Connect" would strand them.
//
// Shown only when NOTHING is configured. A re-login after an expired session
// keeps the server URL, so it goes straight to the fields that are missing.
module Setup {
    function start() {
        WatchUi.pushView(new SetupMenu(), new SetupMenuDelegate(), WatchUi.SLIDE_LEFT);
    }

    // True when the watch holds no configuration at all - neither an on-watch
    // login nor anything from phone settings.
    function isUnconfigured() {
        return AbsApi.serverUrl() == null;
    }
}

class SetupMenu extends WatchUi.Menu2 {
    function initialize() {
        Menu2.initialize({ :title => WatchUi.loadResource(Rez.Strings.setupTitle) });
        // Phone first: it is the one that costs nothing, and a user who can use
        // it should see it before committing to the wheel.
        addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.setupOnPhone),
            null, "phone", null));
        addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.setupOnWatch),
            null, "watch", null));
    }
}

class SetupMenuDelegate extends WatchUi.Menu2InputDelegate {
    function initialize() {
        Menu2InputDelegate.initialize();
    }

    function onSelect(item) {
        var id = item.getId();
        if ((id instanceof Toybox.Lang.String) && id.equals("phone")) {
            WatchUi.pushView(new ErrorView(WatchUi.loadResource(Rez.Strings.setupPhoneHelp)),
                new ErrorViewDelegate(), WatchUi.SLIDE_LEFT);
            return;
        }
        // switchToView, not push: the login flow replaces this screen so Back
        // from the library does not land back on the setup chooser.
        WatchUi.switchToView(new LoginView(), new LibraryViewDelegate(), WatchUi.SLIDE_LEFT);
    }

    function onBack() {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
}
