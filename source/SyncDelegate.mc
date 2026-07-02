using Toybox.Application;
using Toybox.Communications;
using Toybox.Media;

// Downloads queued books to the device media cache, one derived chunk at a
// time. One chunk == one Media track, so the native player gives real chapter
// navigation. Works from the per-book jobs in JobStore - chunk boundaries
// come from Chunks.at(), and each downloaded refId is recorded via
// BookStore.saveChunk (position == chunk index, overwrite-safe). Nothing here
// is ever O(chunks) - or O(queued books x files) - in a single Storage value
// (see Constants.mc for the OOM post-mortem).
//
// STORAGE DISCIPLINE: queue state is read FRESH at every step and only
// read-modify-written - never held in a long-lived field and persisted
// wholesale. A snapshot design silently clobbered any queue change made while
// a sync was running (book queued mid-sync erased after "Queued!" was shown;
// "Clear queue" undone seconds later) and let a deleted book's job survive
// deletion, resurrecting the book with its head chunks permanently missing.
//
// Extends Communications.SyncDelegate. VERIFIED against SDK 9.2.0's api.mir
// (the compiler's own contract, not docs or samples):
// AudioContentProviderApp.getSyncDelegate() is declared
// `as Communications.SyncDelegate or Null`, and Media.SyncDelegate is a
// SEPARATE class (not a subtype), so returning one violates the declared
// contract. Do NOT "fix" this back to Media.SyncDelegate to match the GitHub
// MonkeyMusic sample - that sample is 2018-era and predates the type change;
// build b24 tried exactly that, fixed nothing (both known failures
// persisted), and was reverted.
class SyncDelegate extends Communications.SyncDelegate {

    private var mTotal;      // ops planned at sync start (downloads + deletes)
    private var mDone;       // ops completed

    function initialize() {
        SyncDelegate.initialize();
        mTotal = 0;
        mDone = 0;
    }

    function deletes() {
        var d = Application.Storage.getValue(Store.DELETE_LIST);
        return (d == null) ? [] : d;
    }

    // The system only starts a sync when this is true.
    function isSyncNeeded() {
        return (JobStore.list().size() != 0) || (deletes().size() != 0);
    }

    function onStartSync() {
        var toDelete = deletes();

        // Cancel any queued job for a book being deleted BEFORE counting or
        // downloading anything - otherwise the very sync that deletes the book
        // resumes its job and resurrects it missing its head chunks.
        for (var i = 0; i < toDelete.size(); ++i) {
            JobStore.remove(toDelete[i]);
        }

        mTotal = toDelete.size();
        var jobIds = JobStore.list();
        for (var i = 0; i < jobIds.size(); ++i) {
            var job = JobStore.get(jobIds[i]);
            if (job == null) {
                // Stray index entry (crash window) - heal HERE too, not just
                // in downloadNext: a queue of only strays makes mTotal 0 and
                // returns before downloadNext ever runs, leaving
                // isSyncNeeded() true forever (endless no-op syncs).
                JobStore.remove(jobIds[i]);
                continue;
            }
            var left = Chunks.total(job["durs"]) - job["done"];
            if (left > 0) { mTotal += left; }
        }
        if (mTotal == 0) {
            Communications.notifySyncComplete(null);
            return;
        }

        deleteQueued(toDelete);
        downloadNext();
    }

    // System-initiated cancel: stop cleanly. In-flight request is abandoned;
    // jobs stay in Storage with their cursor, so the next sync resumes.
    function onStopSync() {
        Communications.cancelAllRequests();
        Communications.notifySyncComplete(null);
    }

    // Delete every queued BOOK: BookStore evicts its cached chunks and drops
    // its records; then remove it from the menu index.
    function deleteQueued(toDelete) {
        if (toDelete.size() == 0) { return; }
        for (var i = 0; i < toDelete.size(); ++i) {
            BookStore.deleteBook(toDelete[i]);
            BookStore.removeFromIndex(toDelete[i]);
            onOpDone();
        }

        // Remove ONLY the entries just processed - a delete the UI queued
        // while this loop ran must survive for the next sync, not be
        // silently dropped by a wholesale clear.
        var fresh = deletes();
        var remaining = [];
        for (var i = 0; i < fresh.size(); ++i) {
            if (!containsId(toDelete, fresh[i])) { remaining.add(fresh[i]); }
        }
        if (remaining.size() > 0) {
            Application.Storage.setValue(Store.DELETE_LIST, remaining);
        } else {
            Application.Storage.deleteValue(Store.DELETE_LIST);
        }
    }

    function containsId(arr, itemId) {
        for (var i = 0; i < arr.size(); ++i) {
            if (arr[i].equals(itemId)) { return true; }
        }
        return false;
    }

    // Download the next chunk of the first queued book. Reads the queue fresh
    // so mid-sync queue changes (new book, clear queue, delete) take effect.
    function downloadNext() {
        var jobIds = JobStore.list();
        if (jobIds.size() == 0) {
            sweepOrphans();
            Communications.notifySyncComplete(null);
            return;
        }

        var itemId = jobIds[0];

        // Honor a delete queued mid-sync: stop downloading the doomed book
        // now (its actual deletion runs at the next sync start) instead of
        // pouring hundreds more chunks into a book the user already deleted.
        if (containsId(deletes(), itemId)) {
            JobStore.remove(itemId);
            downloadNext();
            return;
        }

        var job = JobStore.get(itemId);
        if (job == null) {
            // Stray index entry (crash window) - self-heal and move on.
            JobStore.remove(itemId);
            downloadNext();
            return;
        }

        var c = Chunks.at(job["durs"], job["done"]);
        if (c == null) {
            // Book finished (or cursor out of range) - drop the job, move on.
            JobStore.remove(itemId);
            downloadNext();
            return;
        }

        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            // Audio download: hand bytes straight to the media cache.
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_AUDIO,
            // The sidecar always transcodes chunks to AAC/ADTS.
            :mediaEncoding => Media.ENCODING_ADTS
        };

        // "k" pins WHICH chunk this request is for and "gen" pins WHICH job
        // generation dispatched it: if the cursor moved, or the job was
        // replaced wholesale by a re-queue (gen bumps on every re-queue, so
        // even a same-cursor-value collision like 0==0 is caught), recording
        // the stale bytes would put the wrong audio at the wrong position -
        // the callback validates and discards instead.
        var context = { "item" => itemId, "k" => job["done"], "gen" => job["gen"] };
        var delegate = new RequestDelegate(method(:onTrackDownloaded), context);
        var url = AbsApi.sidecarChunkUrl(itemId, job["inos"][c["file"]],
                                        c["cstart"], c["cend"]);
        delegate.makeWebRequest(url, null, options);
    }

    // On success `data` is a Media.ContentRef (the doc's union type is loose,
    // but ContentRef is what an audio download delivers). Record its id at the
    // job's cursor position and advance.
    function onTrackDownloaded(code, data, context) {
        if ((code != 200) || (data == null)) {
            Communications.notifySyncComplete("Download failed (" + code + ")");
            return;
        }

        var itemId = context["item"];
        var refId = data.getId();

        var job = JobStore.get(itemId);
        if ((job == null) || (context["gen"] != job["gen"]) || (context["k"] != job["done"])) {
            // The job was cancelled (cleared/deleted), replaced by a re-queue
            // (generation mismatch), or its cursor moved while this chunk was
            // in flight - these bytes no longer have a valid slot. Evict the
            // now-ownerless cached item and carry on with whatever the queue
            // holds now.
            Media.deleteCachedItem(new Media.ContentRef(refId, Media.CONTENT_TYPE_AUDIO));
            downloadNext();
            return;
        }

        var k = job["done"];
        BookStore.ensureMeta(itemId, job["title"], job["durs"]);
        BookStore.saveChunk(itemId, k, refId);
        BookStore.addToIndex(itemId);

        // Advance + persist the cursor so a crash won't re-fetch. saveChunk is
        // overwrite-by-position, so even a crash between these writes can only
        // cause a harmless re-download, never a duplicate or a skipped chunk.
        job["done"] = k + 1;
        if (job["done"] >= Chunks.total(job["durs"])) {
            JobStore.remove(itemId);
        } else {
            JobStore.put(itemId, job);
        }

        onOpDone();
        downloadNext();
    }

    // Evict cached audio the OS holds that no book's records claim. Orphans
    // come from crash windows (item cached, callback never recorded it) and
    // would otherwise eat media-cache space forever - the cache outlives the
    // app's own bookkeeping. Runs at the end of every sync; bounded by
    // Chunks.MAX_TOTAL known refIds. Orphans are collected first, then
    // evicted - never delete while walking the OS iterator.
    function sweepOrphans() {
        var known = {};
        var index = Application.Storage.getValue(Store.BOOK_INDEX);
        if (index == null) { index = []; }
        for (var b = 0; b < index.size(); ++b) {
            BookStore.addRefIds(index[b], known);
        }
        // Queued books may have recorded chunks that aren't indexed yet
        // (crash between saveChunk and addToIndex) - their pages are still
        // authoritative, so count them as known too.
        var jobIds = JobStore.list();
        for (var i = 0; i < jobIds.size(); ++i) {
            if (!containsId(index, jobIds[i])) {
                BookStore.addRefIds(jobIds[i], known);
            }
        }

        var orphans = [];
        var iter = Media.getContentRefIter({ :contentType => Media.CONTENT_TYPE_AUDIO });
        if (iter != null) {
            var ref = iter.next();
            while (ref != null) {
                if (known[ref.getId()] == null) { orphans.add(ref.getId()); }
                ref = iter.next();
            }
        }
        for (var i = 0; i < orphans.size(); ++i) {
            Media.deleteCachedItem(new Media.ContentRef(orphans[i], Media.CONTENT_TYPE_AUDIO));
        }
    }

    function onOpDone() {
        ++mDone;
        // Mid-sync queue changes can grow/shrink the real work vs the plan
        // made at sync start - clamp so the bar never runs past 100%.
        var pct = ((mDone / mTotal.toFloat()) * 100).toNumber();
        if (pct > 100) { pct = 100; }
        Communications.notifySyncProgress(pct);
    }
}
