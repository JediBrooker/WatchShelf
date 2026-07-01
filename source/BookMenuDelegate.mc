using Toybox.Application;
using Toybox.Communications;
using Toybox.System;
using Toybox.WatchUi;

// Picked a book -> fetch detail, queue its tracks (one per audio FILE, or one per
// chapter for a single-file chaptered book), then run a background sync.
class BookMenuDelegate extends WatchUi.Menu2InputDelegate {

    function initialize() {
        Menu2InputDelegate.initialize();
    }

    function onSelect(item) {
        var itemId = item.getId();
        AbsApi.getItemDetail(itemId, method(:onDetail));
    }

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

        var syncList = Application.Storage.getValue(Store.SYNC_LIST);
        if (syncList == null) { syncList = {}; }

        if (audioFiles.size() == 1 && chapters != null && chapters.size() > 0) {
            // Single-file book WITH chapters: one sidecar-cut track per chapter,
            // for small downloads and real chapter navigation.
            var ino = audioFiles[0]["ino"];
            for (var i = 0; i < chapters.size(); ++i) {
                var ch = chapters[i];
                var start = numOr(ch["start"], 0);
                var end = numOr(ch["end"], start);
                var chTitle = ch["title"];
                if (chTitle == null) { chTitle = "Chapter " + (i + 1); }
                var chUrl = AbsApi.sidecarChapterUrl(itemId, ino, start, end);
                syncList[itemId + ":c" + i] = trackInfo(chUrl, chTitle, "mp3", itemId, start);
            }
        } else {
            // One track per audio FILE. Handles multi-file books (the common case
            // in a real ABS library) and single-file no-chapter books. Book-
            // absolute start = running sum of prior file durations, so progress
            // maps back to ABS correctly.
            var files = sortByIndex(audioFiles);
            var offset = 0;
            for (var i = 0; i < files.size(); ++i) {
                var af = files[i];
                var url = AbsApi.fileTrackUrl(itemId, af);
                var type = AbsApi.fileTrackType(af);
                var partTitle = (files.size() > 1) ? (title + " - Part " + (i + 1)) : title;
                syncList[itemId + ":f" + i] = trackInfo(url, partTitle, type, itemId, offset);
                offset = offset + numOr(af["duration"], 0);
            }
        }

        Application.Storage.setValue(Store.SYNC_LIST, syncList);
        System.println("Resume position (s): " + AbsApi.progressSeconds(data));

        WatchUi.pushView(new ErrorView(WatchUi.loadResource(Rez.Strings.queued)), null, WatchUi.SLIDE_LEFT);
        Communications.startSync();
    }

    // Sort audio files by their ABS `index` (file order), tolerating a missing
    // index. Plain-statement insertion sort (Array.add returns Void in Monkey C).
    function sortByIndex(files) {
        var out = [];
        for (var i = 0; i < files.size(); ++i) {
            var af = files[i];
            var idx = numOr(af["index"], i);
            var pos = out.size();
            for (var j = 0; j < out.size(); ++j) {
                if (idx < numOr(out[j]["index"], j)) { pos = j; break; }
            }
            var rebuilt = new [out.size() + 1];
            for (var k = 0; k < pos; ++k) { rebuilt[k] = out[k]; }
            rebuilt[pos] = af;
            for (var k = pos; k < out.size(); ++k) { rebuilt[k + 1] = out[k]; }
            out = rebuilt;
        }
        return out;
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

    function numOr(v, dflt) {
        if (v == null) { return dflt; }
        return v;
    }

    function onBack() {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
}