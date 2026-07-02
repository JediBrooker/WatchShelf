using Toybox.Application;
using Toybox.Media;
using Toybox.WatchUi;

// Lists every downloaded chapter track. Selecting an item removes it; the native
// player is what actually plays the ContentIterator's set.
class DownloadedMenu extends WatchUi.Menu2 {

    function initialize() {
        Menu2.initialize({ :title => titleWithSize() });

        // This "Downloaded" screen is where the audio provider first opens, so it
        // MUST lead to the books. Always show a way into the library; LibraryView
        // logs the user in first if they aren't configured yet.
        addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.browseLibrary), null, "browse", null));

        // Only offer to log out if actually logged in - avoids a pointless item
        // on a fresh, unconfigured install.
        if (AbsApi.isConfigured()) {
            addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.logOut), null, "logout", null));
        }

        // A crashed/interrupted sync can leave queued entries behind (they're
        // only cleared as each one finishes downloading), which then get
        // reprocessed on every future sync alongside anything new. Offer a way
        // to wipe just the pending queue - sideloaded apps can't be cleanly
        // uninstalled to reset this, so it has to be reachable from in here.
        if (hasQueued()) {
            addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.clearQueue), null, "clearqueue", null));
        }

        var tracks = Application.Storage.getValue(Store.TRACKS);
        if (tracks == null) { tracks = {}; }

        var refIds = tracks.keys();
        for (var i = 0; i < refIds.size(); ++i) {
            var refId = refIds[i];
            var name = trackTitle(refId, tracks);
            addItem(new WatchUi.MenuItem(name, WatchUi.loadResource(Rez.Strings.tapToDelete), refId, null));
        }
    }

    function hasQueued() {
        var syncList = Application.Storage.getValue(Store.SYNC_LIST);
        var deleteList = Application.Storage.getValue(Store.DELETE_LIST);
        return ((syncList != null) && (syncList.size() > 0))
            || ((deleteList != null) && (deleteList.size() > 0));
    }

    // Prefer the cached media's own metadata title; fall back to stored TrackInfo.
    function trackTitle(refId, tracks) {
        var ref = new Media.ContentRef(refId, Media.CONTENT_TYPE_AUDIO);
        var obj = Media.getCachedContentObj(ref);
        if (obj != null && obj.getMetadata() != null && obj.getMetadata().title != null) {
            return obj.getMetadata().title;
        }
        var info = tracks[refId];
        if (info != null && info[TrackInfo.TITLE] != null) { return info[TrackInfo.TITLE]; }
        return "Track";
    }

    // Show used cache space in the menu title. CacheStatistics exposes `size`
    // (current bytes) and `capacity` (total bytes) - both Lang.Long. There is no
    // `used` field.
    function titleWithSize() {
        var stats = Media.getCacheStatistics();
        var used = 0;
        if (stats != null && stats.size != null) { used = stats.size; }
        var mb = (used / (1024 * 1024)).toNumber();
        return WatchUi.loadResource(Rez.Strings.downloaded) + " " + Versions.tag + " (" + mb + " MB)";
    }
}
