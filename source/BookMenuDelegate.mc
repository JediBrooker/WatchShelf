using Toybox.Application;
using Toybox.Communications;
using Toybox.WatchUi;

// Picked a book -> get its lean file list from the sidecar, store ONE small
// per-book job (file inos + durations + title + resume cursor) via JobStore,
// and run a background sync. Chunk boundaries are derived by the Chunks
// module at download time - never stored per-chunk (see Constants.mc for the
// OOM post-mortem that forced this). Everything goes through the sidecar
// because most books here are single 200MB-1GB files the watch cannot
// download whole.
class BookFilesListener {
    private var mOwner;
    private var mItemId;
    private var mSpeed;

    function initialize(owner, itemId, speed) {
        mOwner = owner;
        mItemId = itemId;
        mSpeed = speed;
    }

    function onResponse(code, data) {
        // Carry the selected id with this specific request. A second rapid tap
        // can start another /files request before this one returns; using one
        // mutable delegate field would then queue the first book's file list
        // under the second book's id and make every transcode fail.
        mOwner.onFiles(mItemId, mSpeed, code, data);
    }
}

class BookSpeedMenu extends WatchUi.Menu2 {
    function initialize(title) {
        Menu2.initialize({ :title => title });
        addItem(new WatchUi.MenuItem("1.0x", null, "100", null));
        addItem(new WatchUi.MenuItem("1.25x", null, "125", null));
        addItem(new WatchUi.MenuItem("1.5x", null, "150", null));
        addItem(new WatchUi.MenuItem("1.75x", null, "175", null));
        addItem(new WatchUi.MenuItem("2.0x", null, "200", null));
    }
}

class BookSpeedMenuDelegate extends WatchUi.Menu2InputDelegate {
    private var mOwner;
    private var mItemId;

    function initialize(owner, itemId) {
        Menu2InputDelegate.initialize();
        mOwner = owner;
        mItemId = itemId;
    }

    function onSelect(item) {
        var speed = item.getId().toNumber();
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
        mOwner.downloadAtSpeed(mItemId, PlaybackSpeed.normalize(speed));
    }

    function onBack() {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
}

class BookMenuDelegate extends WatchUi.Menu2InputDelegate {

    function initialize() {
        Menu2InputDelegate.initialize();
    }

    function onSelect(item) {
        var itemId = item.getId();
        WatchUi.pushView(new BookSpeedMenu(WatchUi.loadResource(Rez.Strings.chooseSpeed)),
            new BookSpeedMenuDelegate(self, itemId), WatchUi.SLIDE_LEFT);
    }

    function downloadAtSpeed(itemId, speed) {
        var listener = new BookFilesListener(self, itemId, speed);
        AbsApi.getFiles(itemId, listener.method(:onResponse));
    }

    function onFiles(itemId, speed, code, data) {
        // Session expired -> re-login instead of a dead-end error.
        if (code == 401) { Login.reauth(); return; }
        if (code != 200 || data == null) {
            WatchUi.pushView(new ErrorView(Errors.message(Rez.Strings.errDetail, code)),
                new ErrorViewDelegate(), WatchUi.SLIDE_LEFT);
            return;
        }

        // Book has more audio files than the watch can hold. The sidecar
        // deliberately sent NO file list (shipping hundreds of entries would
        // OOM the watch's 512KB heap while parsing) - just a flag. Reject
        // cleanly instead of the old "Media Error Occurred" crash.
        if (data["tooManyFiles"] == true) {
            WatchUi.pushView(new ErrorView(WatchUi.loadResource(Rez.Strings.errTooManyFiles)),
                new ErrorViewDelegate(), WatchUi.SLIDE_LEFT);
            return;
        }

        if (data["files"] == null || data["files"].size() == 0) {
            WatchUi.pushView(new ErrorView(Errors.message(Rez.Strings.errDetail, code)),
                new ErrorViewDelegate(), WatchUi.SLIDE_LEFT);
            return;
        }

        var files = data["files"];

        // Gate on file count BEFORE building the O(files) inos/durs arrays
        // below (a stale sidecar that doesn't cap could still hand us a big
        // list). Job values are O(files); past ~600 files the single job value
        // approaches the 32KB Storage cap (long inode strings included).
        if (files.size() > JobStore.MAX_FILES) {
            WatchUi.pushView(new ErrorView(WatchUi.loadResource(Rez.Strings.errTooManyFiles)),
                new ErrorViewDelegate(), WatchUi.SLIDE_LEFT);
            return;
        }

        var title = data["title"];
        if (title == null) { title = "Book"; }
        // Author rides along for player metadata (artist line). Older sidecars
        // don't send it - null is fine everywhere downstream.
        var author = data["author"];

        var inos = [];
        var durs = [];
        for (var f = 0; f < files.size(); ++f) {
            var dur = numOr(files[f]["duration"], 0).toNumber();
            if (dur <= 0) { continue; }
            inos.add(files[f]["ino"]);
            durs.add(dur);
        }

        var expected = Chunks.total(durs);
        if (expected == 0) {
            WatchUi.pushView(new ErrorView(WatchUi.loadResource(Rez.Strings.errNoAudio)), new ErrorViewDelegate(), WatchUi.SLIDE_LEFT);
            return;
        }

        // /files carries the user's ABS position. Merge it into the same LWW
        // store playback uses, then choose the local winner below. A finished
        // winner means the user selected this title from All books for a reread:
        // download from chunk 0 and hide Resume, never map its end cursor back to
        // the final part. A genuinely newer local rewind still wins an equal or
        // older server finish.
        var remoteProgress = data["progress"];
        var localProgress = Progress.get(itemId);
        var forceFull = Progress.entryFinished(localProgress);
        if (remoteProgress != null) {
            if (remoteProgress["isFinished"] == true) {
                var remoteTs = remoteProgress["lastUpdate"];
                if ((localProgress == null) ||
                    ((remoteTs != null) && (remoteTs > localProgress[1]))) {
                    var finishedPull = AbsApi.readProgress(remoteProgress);
                    if (finishedPull != null) {
                        Progress.mergeServer(itemId, finishedPull[0],
                            finishedPull[1], finishedPull[2]);
                        localProgress = Progress.get(itemId);
                    }
                    forceFull = true;
                }
            } else {
                var pulled = AbsApi.readProgress(remoteProgress);
                if (pulled != null) {
                    Progress.mergeServer(itemId, pulled[0], pulled[1], pulled[2]);
                    localProgress = Progress.get(itemId);
                }
            }
        }
        if (Progress.entryFinished(localProgress)) { forceFull = true; }
        var progressBase = (!forceFull && (localProgress != null))
            ? Chunks.indexAt(durs, localProgress[0]) : 0;
        if (progressBase >= expected) {
            showNothingToDownload();
            return;
        }

        // GATE ORDER MATTERS: every early-return gate below runs BEFORE the
        // destructive drift wipe. Wiping first and then rejecting would strand
        // a live job pointing at deleted pages - the sync then resumes it
        // mid-book, pads the missing head with nulls, and the book "completes"
        // with silent holes (or, past page 0, its fresh downloads get
        // orphan-swept and its pages leak). Nothing is destroyed until this
        // selection is definitely going to queue. (The file-count cap is
        // enforced above, before the inos/durs arrays are even built.)

        // Duration drift: this book was downloaded (fully or partly) against
        // DIFFERENT per-file durations (server re-transcoded/replaced files),
        // so its recorded start offsets no longer match the boundaries new
        // chunks would be cut at - it must restart clean. Same treatment for
        // a corrupt partial: records exist but the book isn't indexed AND
        // isn't queued (a crash artifact whose audio the orphan sweep may
        // already have evicted).
        var meta = BookStore.get(itemId);
        var oldJob = JobStore.get(itemId);
        var drifted = false;
        if (meta != null) {
            drifted = (forceFull && (BookStore.first(itemId) > 0))
                || !Chunks.same(meta["durs"], durs)
                || (PlaybackSpeed.normalize(meta["speed"]) != speed)
                || (!inBookIndex(itemId) && !containsId(JobStore.list(), itemId));
        }

        // Preserve the original suffix base whenever this is an interrupted
        // download. Changing it underneath already-local pages would reinterpret
        // every cached refId as a different absolute chunk. Only a genuinely new
        // (or drift-wiped) book derives its first required chunk from progress.
        var base = 0;
        if (!drifted && (meta != null)) {
            base = BookStore.first(itemId);
        } else if (!drifted && (oldJob != null) && (oldJob["base"] != null)) {
            base = oldJob["base"];
        } else {
            base = progressBase;
        }
        if (base < 0) { base = 0; }
        if (base >= expected) {
            showNothingToDownload();
            return;
        }
        var planned = expected - base;

        // Re-selecting an already-fully-downloaded book must not silently queue
        // a full re-download - tell the user it's already there instead. A
        // drifted book is never "already there": its data is scheduled to go.
        if (!drifted && (BookStore.count(itemId) >= planned)) {
            WatchUi.pushView(new ErrorView(WatchUi.loadResource(Rez.Strings.alreadyDownloaded)),
                new ErrorViewDelegate(), WatchUi.SLIDE_LEFT);
            return;
        }

        // Total-chunk cap: playback builds O(total chunks) structures inside
        // the 512KB audioContentProvider ceiling, so the watch-wide total
        // (downloaded + queued, all books) is bounded - see Chunks.MAX_TOTAL.
        if (plannedChunks(itemId) + planned > Chunks.MAX_TOTAL) {
            WatchUi.pushView(new ErrorView(WatchUi.loadResource(Rez.Strings.downloadsFull)),
                new ErrorViewDelegate(), WatchUi.SLIDE_LEFT);
            return;
        }

        // Read the superseded job's generation BEFORE the wipe removes it, so
        // "gen" always increments across a drift wipe too - an in-flight chunk
        // dispatched under the old job can then never collide with the new one.
        var gen = ((oldJob != null) && (oldJob["gen"] != null)) ? oldJob["gen"] + 1 : 1;

        // All gates passed - NOW it is safe to destroy the drifted book's
        // state. JOB FIRST: deleteBook is hundreds of Storage ops, and a
        // hard kill mid-wipe with the job still queued would leave that job
        // resuming over truncated pages (null-padded silent holes). With the
        // job already gone, a mid-wipe crash decays to a benign partial that
        // the stranded/orphan machinery cleans up. Then UN-INDEX before evict,
        // so a kill between them leaves an unindexed book with orphan chunks
        // (swept next sync) rather than an indexed book with zero chunks (which
        // would make playback start a different book). Progress is NOT pruned:
        // it's the SAME book re-downloading, so its resume point stays valid.
        if (drifted) {
            JobStore.remove(itemId);
            BookStore.removeFromIndex(itemId);
            BookStore.deleteBook(itemId);
        }

        // Queueing a book un-dooms it: if it's still sitting in DELETE_LIST
        // from an earlier delete, the next sync's cancel-then-delete pass
        // would silently eat this fresh job and wipe the book right after
        // the user saw "Queued" - the newer intent (download) wins.
        var doomed = Application.Storage.getValue(Store.DELETE_LIST);
        if ((doomed != null) && containsId(doomed, itemId)) {
            var kept = [];
            for (var i = 0; i < doomed.size(); ++i) {
                if (!doomed[i].equals(itemId)) { kept.add(doomed[i]); }
            }
            Application.Storage.setValue(Store.DELETE_LIST, kept);
        }

        // One small job per book. `base` is the first GLOBAL chunk still needed
        // when the job was created; listened head chunks are never downloaded.
        // `done` is also GLOBAL, while BookStore pages are local to meta.first.
        // An interrupted suffix therefore resumes at first+count without sparse
        // pages or null placeholders. "gen" still invalidates in-flight bytes
        // from every superseded job.
        var done = (!drifted && (meta != null)) ? BookStore.nextChunk(itemId) : base;
        JobStore.put(itemId, {
            "inos"   => inos,
            "durs"   => durs,
            "title"  => title,
            "author" => author,
            "speed"  => speed,
            "base"   => base,
            "done"   => done,
            "gen"    => gen
        });

        Notify.flash(Rez.Strings.queued);
        Communications.startSync();
    }

    // Chunks already committed to the watch (downloaded or queued, all books),
    // excluding `excludeId` (the book being re-queued - its own chunks are
    // accounted for by the caller's `expected`) and any book queued for
    // DELETION (its chunks are scheduled to go - counting them would reject
    // the exact "delete a book, then queue a replacement" flow the
    // "Downloads full" message tells the user to perform). Queued books count
    // at their FULL size since they will finish; non-queued downloaded books
    // count at their recorded size.
    function plannedChunks(excludeId) {
        var total = 0;

        var doomed = Application.Storage.getValue(Store.DELETE_LIST);
        if (doomed == null) { doomed = []; }

        var jobIds = JobStore.list();
        for (var i = 0; i < jobIds.size(); ++i) {
            if (jobIds[i].equals(excludeId) || containsId(doomed, jobIds[i])) { continue; }
            var job = JobStore.get(jobIds[i]);
            if (job != null) {
                var base = (job["base"] != null) ? job["base"] : 0;
                var planned = Chunks.total(job["durs"]) - base;
                if (planned > 0) { total += planned; }
            }
        }

        var index = Application.Storage.getValue(Store.BOOK_INDEX);
        if (index == null) { index = []; }
        for (var i = 0; i < index.size(); ++i) {
            if (index[i].equals(excludeId) || containsId(jobIds, index[i])
                || containsId(doomed, index[i])) { continue; }
            total += BookStore.count(index[i]);
        }
        return total;
    }

    function containsId(arr, itemId) {
        for (var i = 0; i < arr.size(); ++i) {
            if (arr[i].equals(itemId)) { return true; }
        }
        return false;
    }

    function inBookIndex(itemId) {
        var index = Application.Storage.getValue(Store.BOOK_INDEX);
        if (index == null) { return false; }
        return containsId(index, itemId);
    }

    function numOr(v, dflt) {
        if (v == null) { return dflt; }
        return v;
    }

    function showNothingToDownload() {
        WatchUi.pushView(new ErrorView(WatchUi.loadResource(Rez.Strings.nothingToDownload)),
            new ErrorViewDelegate(), WatchUi.SLIDE_LEFT);
    }

    function onBack() {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
}
