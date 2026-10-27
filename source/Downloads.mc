using Toybox.Application;
using Toybox.Communications;
using Toybox.Lang;

// Shared deletion path for downloaded books - used by the per-book action menu
// (one book) and the "Delete all downloads" confirmation (every book). Queue the
// whole books and kick a sync; SyncDelegate.deleteQueued evicts each cached
// chunk. Whole-book only: per-chunk state is what used to OOM-crash the app
// (see Constants.mc).
module Downloads {
    function queueDelete(itemIds) {
        if (itemIds.size() == 0) { return; }
        PodcastSettings.cancelPending();
        var deleteList = Application.Storage.getValue(Store.DELETE_LIST);
        if (deleteList == null) { deleteList = []; }
        for (var i = 0; i < itemIds.size(); ++i) {
            if (PodcastSettings.owner(itemIds[i]) != null) { PodcastSettings.suppress(itemIds[i]); }
            deleteList.add(itemIds[i]);
        }
        Application.Storage.setValue(Store.DELETE_LIST, deleteList);
        Communications.startSync();
        Notify.flash(Rez.Strings.deleting);
    }

    // The foreground and automatic engine share every file, resume, variant,
    // storage and job-generation gate. Null means queued; a resource id is an
    // actionable error for the foreground. No UI or network side effects here.
    function queue(itemId, speed, data, automatic) {
        if (automatic && !automaticIndexFits(itemId)) { return Rez.Strings.downloadsFull; }
        if (!automatic) { PodcastSettings.adopt(itemId); }
        if (!(data instanceof Lang.Dictionary)) { return Rez.Strings.errNoAudio; }
        // Book has more audio files than the watch can hold. The sidecar
        // deliberately sent NO file list (shipping hundreds of entries would
        // OOM the watch's 512KB heap while parsing) - just a flag. Reject
        // cleanly instead of the old "Media Error Occurred" crash.
        if (data["tooManyFiles"] == true) {
            return Rez.Strings.errTooManyFiles;
        }

        if (!(data["files"] instanceof Lang.Array) || data["files"].size() == 0) {
            return Rez.Strings.errDetail;
        }

        var files = data["files"];
        if (!(files instanceof Lang.Array)) { return Rez.Strings.errNoAudio; }

        // Gate on file count BEFORE building the O(files) inos/durs arrays
        // below (a stale sidecar that doesn't cap could still hand us a big
        // list). Job values are O(files); past ~600 files the single job value
        // approaches the 32KB Storage cap (long inode strings included).
        if (files.size() > JobStore.MAX_FILES) {
            return Rez.Strings.errTooManyFiles;
        }

        var title = data["title"];
        if (title == null) { title = "Book"; }
        if (!(title instanceof Lang.String)) { return Rez.Strings.errNoAudio; }
        if (title.length() > 180) { title = title.substring(0, 180); }
        // Author rides along for player metadata (artist line). Older sidecars
        // don't send it - null is fine everywhere downstream.
        var author = data["author"];
        if ((author != null) && !(author instanceof Lang.String)) { return Rez.Strings.errNoAudio; }
        if ((author != null) && (author.length() > 180)) { author = author.substring(0, 180); }

        var sumDuration = 0;
        var inos = [];
        var durs = [];
        for (var f = 0; f < files.size(); ++f) {
            if (!(files[f] instanceof Lang.Dictionary)) { return Rez.Strings.errNoAudio; }
            var raw = files[f]["duration"];
            if (!numeric(raw) || (raw < 0) || (raw > 1000000000)) {
                return Rez.Strings.errNoAudio;
            }
            var dur = raw.toNumber();
            var ino = files[f]["ino"];
            if ((ino == null) || (!(ino instanceof Lang.String) && !numeric(ino))) {
                return Rez.Strings.errNoAudio;
            }
            // Real ABS filesystem inodes are at most 20 ASCII digits. Keep
            // a small compatibility margin while bounding a 600-file job to
            // safely below Storage's 32KB per-value ceiling (also with UTF-8
            // titles). Never allow 96-byte file IDs to multiply across a job.
            var textIno = ino.toString();
            if (textIno.length() == 0 || textIno.length() > 24) { return Rez.Strings.errNoAudio; }
            var chars = textIno.toCharArray();
            for (var j = 0; j < chars.size(); ++j) {
                var ascii = chars[j].toNumber();
                if (ascii < 32 || ascii > 126) { return Rez.Strings.errNoAudio; }
            }
            sumDuration += dur;
            if (sumDuration > 1000000000) { return Rez.Strings.errNoAudio; }
            if (dur <= 0) { continue; }
            inos.add(files[f]["ino"]);
            durs.add(dur);
        }

        var expected = Chunks.total(durs);
        if (expected == 0) {
            return Rez.Strings.errNoAudio;
        }

        // /files carries the user's ABS position. Merge it into the same LWW
        // store playback uses, then choose the local winner below. A finished
        // winner means the user selected this title from All books for a reread:
        // download from chunk 0 and hide Resume, never map its end cursor back to
        // the final part. A genuinely newer local rewind still wins an equal or
        // older server finish.
        // Automatic discovery must never turn a locally finished episode into
        // a reread while its completion is still waiting to reach the server.
        if (automatic && Progress.isFinished(itemId)) { return Rez.Strings.nothingToDownload; }
        var remoteProgress = data["progress"];
        if ((remoteProgress != null) && !validProgress(remoteProgress)) { return Rez.Strings.errNoAudio; }
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
        if (automatic && forceFull) { return Rez.Strings.nothingToDownload; }
        var progressBase = (!forceFull && (localProgress != null))
            ? Chunks.indexAt(durs, localProgress[0]) : 0;
        if (progressBase >= expected) {
            return Rez.Strings.nothingToDownload;
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
        if (automatic && (containsId(deleteIds(), itemId) || (JobStore.get(itemId) != null))) {
            return Rez.Strings.alreadyDownloaded;
        }
        var meta = BookStore.get(itemId);
        var oldJob = JobStore.get(itemId);
        var drifted = false;
        var speedOnly = false;
        if (meta != null) {
            // Separate a pure SPEED change from the destructive kinds. Duration
            // drift and crash artifacts invalidate the recorded offsets and must
            // wipe; a different speed does not - the same audio is simply wanted
            // at a different tempo, and the existing encoding is still perfectly
            // good for the speed it was made at.
            var hardDrift = (forceFull && (BookStore.first(itemId) > 0))
                || !Chunks.same(meta["durs"], durs)
                || (!inBookIndex(itemId) && !containsId(JobStore.list(), itemId));
            var speedDrift = (BookStore.activeSpeed(itemId) != speed);
            drifted = hardDrift || speedDrift;
            speedOnly = speedDrift && !hardDrift;
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
            return Rez.Strings.nothingToDownload;
        }
        var planned = expected - base;

        // Re-selecting an already-fully-downloaded book must not silently queue
        // a full re-download - tell the user it's already there instead. A
        // drifted book is never "already there": its data is scheduled to go.
        if (!drifted && (BookStore.count(itemId) >= planned)) {
            return Rez.Strings.alreadyDownloaded;
        }

        // Total-chunk cap: playback builds O(total chunks) structures inside
        // the 512KB audioContentProvider ceiling, so the watch-wide total
        // (downloaded + queued, all books) is bounded - see Chunks.MAX_TOTAL.
        if (plannedChunks(itemId) + planned + (!drifted ? (BookStore.totalChunks(itemId) - BookStore.count(itemId)) : 0) > Chunks.MAX_TOTAL) {
            return Rez.Strings.downloadsFull;
        }

        // Read the superseded job's generation BEFORE the wipe removes it, so
        // "gen" always increments across a drift wipe too - an in-flight chunk
        // dispatched under the old job can then never collide with the new one.
        var gen = JobStore.nextGeneration();
        if ((oldJob != null) && (oldJob["gen"] != null) && gen <= oldJob["gen"]) {
            gen = oldJob["gen"] + 1;
            Application.Storage.setValue("jobGeneration", gen);
        }

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
            if (speedOnly) {
                // Park the encoding being replaced in the other slot so
                // switching back to it is instant, but ONLY if both fit under
                // Chunks.MAX_TOTAL - a parked variant is still cached audio and
                // the cap exists to keep playback inside the 512KB ceiling.
                // When there is no room it is evicted instead, which degrades to
                // exactly the old behaviour rather than failing the download.
                var keep = (plannedChunks(itemId) + planned + BookStore.count(itemId))
                    <= Chunks.MAX_TOTAL;
                BookStore.beginVariant(itemId, speed, base, keep);
                // NOT un-indexed: the book still exists and, when kept, still
                // has real playable audio in the other slot.
            } else {
                BookStore.removeFromIndex(itemId);
                BookStore.deleteBook(itemId);
            }
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
            "autoShow" => automatic ? PodcastSettings.owner(itemId)["show"] : null,
            "autoGeneration" => automatic ? PodcastSettings.owner(itemId)["generation"] : null,
            "gen"    => gen
        });

        return null;
    }

    // Long composite podcast IDs can fill a 32KB index before 1,500 audio
    // chunks are reached. Bound the union (each individual index is smaller)
    // to 24KiB with serialization/Unicode margin. No third inventory is built.
    function indexEntryBytes(id) {
        var chars = id.toCharArray(); var ascii = true;
        for (var i = 0; i < chars.size(); ++i) {
            if (chars[i].toNumber() > 127) { ascii = false; break; }
        }
        return 16 + chars.size() * (ascii ? 1 : 4);
    }
    function automaticIndexFits(itemId) {
        var index = Application.Storage.getValue(Store.BOOK_INDEX);
        if (index == null) { index = []; }
        var jobs = JobStore.list(); var bytes = 32;
        var found = false;
        for (var i = 0; i < index.size(); ++i) {
            bytes += indexEntryBytes(index[i]);
            if (index[i].equals(itemId)) { found = true; }
            if (bytes > 24576) { return false; }
        }
        for (var i = 0; i < jobs.size(); ++i) {
            if (!containsId(index, jobs[i])) { bytes += indexEntryBytes(jobs[i]); }
            if (jobs[i].equals(itemId)) { found = true; }
            if (bytes > 24576) { return false; }
        }
        if (!found) { bytes += indexEntryBytes(itemId); }
        return bytes <= 24576;
    }

    function numeric(v) {
        return ((v instanceof Lang.Number) || (v instanceof Lang.Float)
            || (v instanceof Lang.Long) || (v instanceof Lang.Double)) && (v == v);
    }

    function validProgress(p) {
        if (!(p instanceof Lang.Dictionary)) { return false; }
        return numeric(p["currentTime"]) && numeric(p["lastUpdate"])
            && (p["currentTime"] >= 0) && (p["currentTime"] <= 1000000000)
            && (p["lastUpdate"] >= 0) && (p["lastUpdate"] <= 2147483647)
            && ((p["isFinished"] == true) || (p["isFinished"] == false));
    }

    function deleteIds() {
        var ids = Application.Storage.getValue(Store.DELETE_LIST);
        return (ids == null) ? [] : ids;
    }

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
                total += BookStore.totalChunks(jobIds[i]) - BookStore.count(jobIds[i]);
            }
        }

        var index = Application.Storage.getValue(Store.BOOK_INDEX);
        if (index == null) { index = []; }
        for (var i = 0; i < index.size(); ++i) {
            if (index[i].equals(excludeId) || containsId(jobIds, index[i])
                || containsId(doomed, index[i])) { continue; }
            total += BookStore.totalChunks(index[i]);
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

}
