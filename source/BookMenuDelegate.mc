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
class BookMenuDelegate extends WatchUi.Menu2InputDelegate {

    private var mItemId;

    function initialize() {
        Menu2InputDelegate.initialize();
        mItemId = null;
    }

    function onSelect(item) {
        mItemId = item.getId();
        AbsApi.getFiles(mItemId, method(:onFiles));
    }

    function onFiles(code, data) {
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
        var meta = BookStore.get(mItemId);
        var drifted = false;
        if (meta != null) {
            drifted = !Chunks.same(meta["durs"], durs)
                || (!inBookIndex(mItemId) && !containsId(JobStore.list(), mItemId));
        }

        // Re-selecting an already-fully-downloaded book must not silently queue
        // a full re-download - tell the user it's already there instead. A
        // drifted book is never "already there": its data is scheduled to go.
        if (!drifted && (BookStore.count(mItemId) >= expected)) {
            WatchUi.pushView(new ErrorView(WatchUi.loadResource(Rez.Strings.alreadyDownloaded)),
                new ErrorViewDelegate(), WatchUi.SLIDE_LEFT);
            return;
        }

        // Total-chunk cap: playback builds O(total chunks) structures inside
        // the 512KB audioContentProvider ceiling, so the watch-wide total
        // (downloaded + queued, all books) is bounded - see Chunks.MAX_TOTAL.
        if (plannedChunks(mItemId) + expected > Chunks.MAX_TOTAL) {
            WatchUi.pushView(new ErrorView(WatchUi.loadResource(Rez.Strings.downloadsFull)),
                new ErrorViewDelegate(), WatchUi.SLIDE_LEFT);
            return;
        }

        // Read the superseded job's generation BEFORE the wipe removes it, so
        // "gen" always increments across a drift wipe too - an in-flight chunk
        // dispatched under the old job can then never collide with the new one.
        var oldJob = JobStore.get(mItemId);
        var gen = ((oldJob != null) && (oldJob["gen"] != null)) ? oldJob["gen"] + 1 : 1;

        // All gates passed - NOW it is safe to destroy the drifted book's
        // state. JOB FIRST: deleteBook is hundreds of Storage ops, and a
        // hard kill mid-wipe with the job still queued would leave that job
        // resuming over truncated pages (null-padded silent holes). With the
        // job already gone, a mid-wipe crash decays to a benign partial that
        // the stranded/orphan machinery cleans up.
        if (drifted) {
            JobStore.remove(mItemId);
            BookStore.deleteBook(mItemId);
            BookStore.removeFromIndex(mItemId);
        }

        // Queueing a book un-dooms it: if it's still sitting in DELETE_LIST
        // from an earlier delete, the next sync's cancel-then-delete pass
        // would silently eat this fresh job and wipe the book right after
        // the user saw "Queued" - the newer intent (download) wins.
        var doomed = Application.Storage.getValue(Store.DELETE_LIST);
        if ((doomed != null) && containsId(doomed, mItemId)) {
            var kept = [];
            for (var i = 0; i < doomed.size(); ++i) {
                if (!doomed[i].equals(mItemId)) { kept.add(doomed[i]); }
            }
            Application.Storage.setValue(Store.DELETE_LIST, kept);
        }

        // One small job per book. "done" starts at the already-downloaded chunk
        // count so an interrupted book resumes where it left off (chunks always
        // download in order, so count == next index). "gen" increments on every
        // re-queue so an in-flight chunk from a superseded job can never be
        // recorded into the new one, even at the same cursor value.
        var have = drifted ? 0 : BookStore.count(mItemId);
        JobStore.put(mItemId, {
            "inos"   => inos,
            "durs"   => durs,
            "title"  => title,
            "author" => author,
            "done"   => have,
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
            if (job != null) { total += Chunks.total(job["durs"]); }
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

    function onBack() {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
}
