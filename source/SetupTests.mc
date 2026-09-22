using Toybox.Application;
using Toybox.Test;

// The first-run chooser exists because typing a login on the character wheel
// costs ~359 button presses, while Garmin Connect settings cost none. These
// pin WHEN it is offered - showing it to someone who is only re-authenticating
// would be noise, and hiding it from a first-time user wastes the whole point.

(:test)
function setupOfferedOnlyWhenNothingIsConfigured(logger) {
    var srv = Application.Storage.getValue(Store.SERVER);
    var tok = Application.Storage.getValue(Store.TOKEN);
    Application.Storage.deleteValue(Store.SERVER);
    Application.Storage.deleteValue(Store.TOKEN);

    // Nothing at all: the phone route is worth offering.
    Test.assertMessage(Setup.isUnconfigured(), "a fresh watch gets the chooser");

    // A known server with a dead token is a RE-login: the URL is retained, so
    // only the short fields remain and the chooser would just be in the way.
    Application.Storage.setValue(Store.SERVER, "https://shelf.example.com");
    Test.assertMessage(!Setup.isUnconfigured(), "re-login skips the chooser");
    Test.assertMessage(!AbsApi.isConfigured(), "but it is still not usable yet");

    Application.Storage.deleteValue(Store.SERVER);
    if (srv != null) { Application.Storage.setValue(Store.SERVER, srv); }
    if (tok != null) { Application.Storage.setValue(Store.TOKEN, tok); }
    logger.debug("chooser appears on a fresh watch, not on a re-login");
    return true;
}

// The claim the chooser is built on: phone settings alone fully configure the
// app, so a store user need never touch the wheel. If this stopped being true
// the chooser would be sending people down a dead end.
(:test)
function phoneSettingsAloneFullyConfigure(logger) {
    var srv = Application.Storage.getValue(Store.SERVER);
    var tok = Application.Storage.getValue(Store.TOKEN);
    Application.Storage.deleteValue(Store.SERVER);
    Application.Storage.deleteValue(Store.TOKEN);
    Test.assertMessage(!AbsApi.isConfigured(), "nothing on the watch");

    // Properties are what Garmin Connect writes. Setting BOTH must be enough.
    Application.Properties.setValue(Settings.SERVER_URL, "https://shelf.example.com");
    Application.Properties.setValue(Settings.API_KEY, "abs-api-key");
    Test.assertEqual(AbsApi.serverUrl(), "https://shelf.example.com");
    Test.assertEqual(AbsApi.authToken(), "abs-api-key");
    Test.assertMessage(AbsApi.isConfigured(), "phone settings alone must suffice");

    // An on-watch login still wins when present - it is the fresher intent.
    Application.Storage.setValue(Store.SERVER, "https://watch.example.com");
    Test.assertEqual(AbsApi.serverUrl(), "https://watch.example.com");

    Application.Properties.setValue(Settings.SERVER_URL, "");
    Application.Properties.setValue(Settings.API_KEY, "");
    Application.Storage.deleteValue(Store.SERVER);
    Application.Storage.deleteValue(Store.TOKEN);
    if (srv != null) { Application.Storage.setValue(Store.SERVER, srv); }
    if (tok != null) { Application.Storage.setValue(Store.TOKEN, tok); }
    logger.debug("phone settings alone configure the app; on-watch login wins over them");
    return true;
}
