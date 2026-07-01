using Toybox.Application;
using Toybox.Communications;
using Toybox.Media;

// Downloads queued CHAPTER tracks to the device media cache. One chapter == one
// Media track, so the native player gives real chapter navigation (we never
// flatten a book into a single track). Mirrors MonkeyMusic's SyncDelegate but
// operates on chapter tracks and reports progress via Communications.notify*.
// Extends Communications.SyncDelegate (Media.SyncDelegate is deprecated on SDK 9.x,
// and getSyncDelegate() must now return a Communications.SyncDelegate).
class SyncDelegate extends Communications.SyncDelegate {

    private var mSyncList;   // { trackKey => TrackInfo }
    private var mDeleteList; // [ refId, ... ]
    private var mKeys;       // ordered keys of mSyncList we still need to fetch
    private var mTotal;      // total ops (downloads + deletes) for progress math
    private var mDone;       // ops completed

    function initialize() {
        SyncDelegate.initialize();

        mSyncList = Application.Storage.getValue(Store.SYNC_LIST);
        if (mSyncList == null) { mSyncList = {}; }

        mDeleteList = Application.Storage.getValue(Store.DELETE_LIST);
        if (mDeleteList == null) { mDeleteList = []; }

        mDone = 0;
    }

    // The system only starts a sync when this is true.
    function isSyncNeeded() {
        return (mSyncList.size() != 0) || (mDeleteList.size() != 0);
    }

    function onStartSync() {
        mTotal = mSyncList.size() + mDeleteList.size();
        if (mTotal == 0) {
            Communications.notifySyncComplete(null);
            return;
        }
        deleteQueued();
        mKeys = mSyncList.keys();
        downloadNext();
    }

    // System-initiated cancel: stop cleanly. In-flight request is abandoned.
    function onStopSync() {
        Communications.cancelAllRequests();
        Communications.notifySyncComplete(null);
    }

    // Delete every queued refId from the media cache, then clear the queue.
    function deleteQueued() {
        var tracks = Application.Storage.getValue(Store.TRACKS);
        if (tracks == null) { tracks = {}; }

        for (var i = 0; i < mDeleteList.size(); ++i) {
            var refId = mDeleteList[i];
            Media.deleteCachedItem(new Media.ContentRef(refId, Media.CONTENT_TYPE_AUDIO));
            tracks.remove(refId);
            onOpDone();
        }
        Application.Storage.setValue(Store.TRACKS, tracks);
        Application.Storage.deleteValue(Store.DELETE_LIST);
        mDeleteList = [];
    }

    // Download the next queued chapter track as audio.
    function downloadNext() {
        if (mKeys.size() == 0) {
            Application.Storage.setValue(Store.SYNC_LIST, {});
            Communications.notifySyncComplete(null);
            return;
        }

        var key = mKeys[0];
        var info = mSyncList[key];

        // Context we want back in the callback so we can record the ContentRef.
        var context = { "key" => key, "info" => info };

        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            // Audio download: hand bytes straight to the media cache.
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_AUDIO,
            // Encoding MUST match what the server/sidecar actually returns.
            :mediaEncoding => typeToEncoding(info[TrackInfo.TYPE])
        };

        var delegate = new RequestDelegate(method(:onTrackDownloaded), context);
        delegate.makeWebRequest(info[TrackInfo.URL], null, options);
    }

    // mp3 -> MP3, m4a -> M4A. Anything else is invalid and the download fails.
    function typeToEncoding(type) {
        if (type.equals("mp3")) { return Media.ENCODING_MP3; }
        if (type.equals("m4a")) { return Media.ENCODING_M4A; }
        if (type.equals("adts")) { return Media.ENCODING_ADTS; }
        if (type.equals("wav")) { return Media.ENCODING_WAV; }
        return Media.ENCODING_INVALID;
    }

    // On success `data` is a Media.ContentRef (the doc's union type is loose, but
    // ContentRef is what an audio download delivers). Store its id -> TrackInfo.
    function onTrackDownloaded(code, data, context) {
        if (code == 200) {
            var refId = data.getId();

            var tracks = Application.Storage.getValue(Store.TRACKS);
            if (tracks == null) { tracks = {}; }
            tracks[refId] = context["info"];
            Application.Storage.setValue(Store.TRACKS, tracks);

            // Remove from the pending queue and persist so a crash won't re-fetch.
            mSyncList.remove(context["key"]);
            Application.Storage.setValue(Store.SYNC_LIST, mSyncList);

            onOpDone();

            mKeys = mKeys.slice(1, mKeys.size());
            downloadNext();
        } else {
            Communications.notifySyncComplete("Download failed (" + code + ")");
        }
    }

    function onOpDone() {
        ++mDone;
        var pct = ((mDone / mTotal.toFloat()) * 100).toNumber();
        Communications.notifySyncProgress(pct);
    }
}
