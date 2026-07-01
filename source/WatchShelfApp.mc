using Toybox.Application;
using Toybox.Media;

// WatchShelf: an Audio Content Provider that streams-then-plays Audiobookshelf
// audiobooks. Class hierarchy mirrors Garmin's MonkeyMusic sample verbatim so we
// keep its proven-to-compile shape; only the server logic is swapped for ABS.
class WatchShelfApp extends Application.AudioContentProviderApp {

    function initialize() {
        // Reset caches if the stored data shape changed between versions.
        var version = Application.Storage.getValue(Store.APP_VERSION);
        if (version != Versions.current) {
            Application.Storage.clearValues();
            Media.resetContentCache();
            Application.Storage.setValue(Store.APP_VERSION, Versions.current);
        }
        // NOTE: MonkeyMusic hardcoded a fake auth token here. WatchShelf does NOT:
        // auth is the user's ABS API key read from Application.Properties.
        AudioContentProviderApp.initialize();
    }

    // System -> playback: hand back a delegate that yields cached chapter tracks.
    function getContentDelegate(args) {
        return new ContentDelegate();
    }

    // System -> sync: background download engine. getSyncDelegate() is the
    // sample's mechanism (Media.SyncDelegate). It is deprecated in newer SDKs in
    // favour of the app itself implementing Communications.SyncDelegate, but we
    // keep the sample shape here for a known-good first version.
    function getSyncDelegate() {
        return new SyncDelegate();
    }

    // System -> "configure playback": pick which downloaded books/chapters to play.
    function getPlaybackConfigurationView() {
        return [new LibraryView(LibraryView.MODE_PLAYBACK)];
    }

    // System -> "configure sync": browse ABS libraries -> books -> download.
    function getSyncConfigurationView() {
        return [new LibraryView(LibraryView.MODE_SYNC)];
    }

    // Provider icon shown in the device media menu.
    function getProviderIconInfo() {
        return new Media.ProviderIconInfo(Rez.Drawables.providerIcon, 0xFF8000);
    }
}
