using Toybox.Application;
using Toybox.Media;

// WatchShelf: an Audio Content Provider that streams-then-plays Audiobookshelf
// audiobooks. Class hierarchy mirrors Garmin's MonkeyMusic sample verbatim so we
// keep its proven-to-compile shape; only the server logic is swapped for ABS.
class WatchShelfApp extends Application.AudioContentProviderApp {

    function initialize() {
        // Reset caches if the stored data shape changed between versions -
        // but carry the login (server/token) across: it isn't shape-versioned
        // data, and clearValues() would otherwise silently log the user out
        // on every upgrade.
        var version = Application.Storage.getValue(Store.APP_VERSION);
        if (version != Versions.current) {
            var server = Application.Storage.getValue(Store.SERVER);
            var token = Application.Storage.getValue(Store.TOKEN);
            Application.Storage.clearValues();
            Media.resetContentCache();
            if (server != null) { Application.Storage.setValue(Store.SERVER, server); }
            if (token != null) { Application.Storage.setValue(Store.TOKEN, token); }
            Application.Storage.setValue(Store.APP_VERSION, Versions.current);
        }
        // NOTE: MonkeyMusic hardcoded a fake auth token here. WatchShelf does NOT:
        // auth is the user's ABS API key read from Application.Properties.
        AudioContentProviderApp.initialize();
    }

    // System -> playback: hand back a delegate that yields cached chapter tracks.
    // args is the payload from Media.startPlayback - our BookActionMenu passes
    // { item, mode } so the iterator can resume/start the chosen book; null from
    // the native Music widget (iterator then resumes the most recent book).
    function getContentDelegate(args) {
        return new ContentDelegate(args);
    }

    // System -> sync: background download engine. getSyncDelegate() is the
    // sample's mechanism (Media.SyncDelegate). It is deprecated in newer SDKs in
    // favour of the app itself implementing Communications.SyncDelegate, but we
    // keep the sample shape here for a known-good first version.
    function getSyncDelegate() {
        return new SyncDelegate();
    }

    // System -> "configure playback": manage downloaded books. DownloadedMenu is
    // a Menu2, which handles Back itself, so it's returned directly with its
    // delegate - no plain loading view (and no missing-delegate hang).
    function getPlaybackConfigurationView() {
        return [new DownloadedMenu(), new DownloadedMenuDelegate()];
    }

    // System -> "configure sync": browse ABS libraries -> books -> download.
    // LibraryView is a plain View, so it MUST be paired with an input delegate
    // (LibraryViewDelegate) or Back has no handler -> the config view hangs.
    function getSyncConfigurationView() {
        return [new LibraryView(), new LibraryViewDelegate()];
    }

    // Provider icon shown in the device media menu.
    function getProviderIconInfo() {
        return new Media.ProviderIconInfo(Rez.Drawables.providerIcon, 0xFF8000);
    }
}
