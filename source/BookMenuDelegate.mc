using Toybox.Application;
using Toybox.Communications;
using Toybox.System;
using Toybox.WatchUi;

// Picked a book -> fetch detail, queue every chapter as its own track, then ask
// the system to run a sync (background download).
class BookMenuDelegate extends WatchUi.Menu2InputDelegate {

    function initialize() {
        Menu2InputDelegate.initialize();
    }

    function onSelect(item) {
        var itemId = item.getId();
        AbsApi.getItemDetail(itemId, method(:onDetail));
    }

    // Build one track per chapter. If the book has no chapters, treat the whole
    // book as a single chapter/track.
    function onDetail(code, data) {
        if (code != 200 || data == null || data["media"] == null) {
            WatchUi.pushView(new ErrorView(WatchUi.loadResource(Rez.Strings.errDetail) + "\n(" + code + ")"),
                null, WatchUi.SLIDE_LEFT);
            return;
        }

        var itemId = data["id"];
        var media = data["media"];
        var audioFiles = media["audioFiles"];
        var chapters = media["chapters"];
        var title = "Book";
        if (media["metadata"] != null && media["metadata"]["title"] != null) {
            title = media["metadata"]["title"];
        }

        if (audioFiles == null || audioFiles.size() == 0) {
            WatchUi.pushView(new ErrorView(WatchUi.loadResource(Rez.Strings.errNoAudio)), null, WatchUi.SLIDE_LEFT);
            return;
        }

        // For a first version we key every chapter off the FIRST audio file's ino.
        // Multi-file books whose chapters span files are a known limitation
        // (documented in README / apiConcerns).
        var primary = audioFiles[0];
        var ino = primary["ino"];
        var direct = AbsApi.fileIsDirectPlayable(primary);

        var syncList = Application.Storage.getValue(Store.SYNC_LIST);
        if (syncList == null) { syncList = {}; }

        if (chapters == null || chapters.size() == 0) {
            // Whole-book single track.
            var url = direct ? AbsApi.directFileUrl(itemId, ino)
                             : AbsApi.sidecarChapterUrl(itemId, ino, 0, safeDuration(primary));
            var type = direct ? AbsApi.encodingType(primary) : "mp3";
            syncList[itemId + ":0"] = trackInfo(url, title, type, itemId, 0);
        } else {
            for (var i = 0; i < chapters.size(); ++i) {
                var ch = chapters[i];
                var start = numOr(ch["start"], 0);
                var end = numOr(ch["end"], start);
                var chTitle = ch["title"];
                if (chTitle == null) { chTitle = "Chapter " + (i + 1); }
                // Per-chapter cuts always go through the sidecar (fmt=mp3) so we
                // get a small, complete, seekable file per chapter. ABS itself
                // only serves whole files, so we cannot direct-download a slice.
                var chUrl = AbsApi.sidecarChapterUrl(itemId, ino, start, end);
                syncList[itemId + ":" + i] = trackInfo(chUrl, chTitle, "mp3", itemId, start);
            }
        }

        Application.Storage.setValue(Store.SYNC_LIST, syncList);

        // Log the saved resume position for debugging; native player resumes at
        // chapter boundaries.
        System.println("Resume position (s): " + AbsApi.progressSeconds(data));

        // Confirm and kick off the background sync.
        WatchUi.pushView(new ErrorView(WatchUi.loadResource(Rez.Strings.queued)), null, WatchUi.SLIDE_LEFT);
        Communications.startSync();
    }

    function trackInfo(url, title, type, itemId, start) {
        return {
            TrackInfo.URL      => url,
            TrackInfo.TITLE    => title,
            TrackInfo.TYPE     => type,
            TrackInfo.ITEM_ID  => itemId,
            TrackInfo.START    => start,
            TrackInfo.CAN_SKIP => true
        };
    }

    function safeDuration(audioFile) {
        return numOr(audioFile["duration"], 0);
    }

    function numOr(v, dflt) {
        if (v == null) { return dflt; }
        return v;
    }

    function onBack() {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
}
