using Toybox.Application;
using Toybox.Lang;
using Toybox.Test;

// Issue #44 (b44 report): deleting a 20-hour book sat at 0%. The sync evicted
// every cached part (~417) in one step before it first reported progress. It
// now evicts a batch per event and reports after each one. The real BookStore
// pages and DELETE_LIST run below; only the pause between batches is replaced.
(:test)
class DeleteHarness extends PodcastDelegateHarness {
    var defer = true;   // false: behave as if no Timer could be created
    var pending = null;
    var batches = 0;
    var percents = [];
    function initialize() { PodcastDelegateHarness.initialize(); }
    function later(cb) {
        batches += 1;
        if (!defer) { return false; }
        pending = cb;
        return true;
    }
    function notifyProgress(pct) { PodcastDelegateHarness.notifyProgress(pct); percents.add(pct); }
    // Run the next scheduled batch, as the Timer would.
    function pump() {
        var cb = pending;
        pending = null;
        cb.invoke();
    }
    function drain() {
        var guard = 0;
        while ((pending != null) && (guard < 1000)) { pump(); guard += 1; }
    }
}

(:test)
module DeleteFixtures {
    const BOOK = "__ws_del_book";
    const OTHER = "__ws_del_other";
    // Record `n` chunks of fake audio straight into the book's pages (saveChunk
    // would read-modify-write a page per chunk, which is slow for 300 chunks).
    function downloaded(itemId, n, alt) {
        BookStore.ensureMeta(itemId, "Book", "Author", [n * 180], 0, 100);
        writePages(itemId, BookStore.SLOT_PRIMARY, n);
        if (alt > 0) { writePages(itemId, BookStore.SLOT_ALT, alt); }
        BookStore.addToIndex(itemId);
        Progress.record(itemId, 30, 100, false);
    }
    function writePages(itemId, slot, n) {
        var p = 0;
        while (n > 0) {
            var size = (n > BookStore.PAGE_SIZE) ? BookStore.PAGE_SIZE : n;
            var arr = new [size];
            for (var i = 0; i < size; ++i) { arr[i] = "__ws_del_ref_" + p + "_" + i; }
            Application.Storage.setValue(BookStore.pageKeyFor(itemId, slot, p), arr);
            n -= size; p += 1;
        }
    }
    function clear() {
        PodcastFixtures.clear();
        var ids = [BOOK, OTHER];
        for (var i = 0; i < ids.size(); ++i) {
            BookStore.removeFromIndex(ids[i]);
            BookStore.deleteBook(ids[i]);
            Progress.remove(ids[i]);
        }
    }
    function queue(ids) { Application.Storage.setValue(Store.DELETE_LIST, ids); }
    function left(itemId) { return BookStore.totalChunks(itemId); }
    function list() {
        var d = Application.Storage.getValue(Store.DELETE_LIST);
        return (d == null) ? [] : d;
    }
}

(:test)
function deleteReportsProgressBeforeTheBookIsGone(logger) {
    DeleteFixtures.clear();
    DeleteFixtures.downloaded(DeleteFixtures.BOOK, 300, 0);
    DeleteFixtures.queue([DeleteFixtures.BOOK]);
    var delegate = new DeleteHarness();
    delegate.onStartSync();

    // One batch, then the event ends so the progress bar can move.
    Test.assertEqual(DeleteFixtures.left(DeleteFixtures.BOOK), 300 - WatchShelfSyncDelegate.DELETE_BATCH);
    Test.assertMessage(delegate.lastPct != null, "progress reported after the first batch");
    Test.assertMessage((delegate.lastPct > 0) && (delegate.lastPct < 100), "and it is part-way: " + delegate.lastPct);
    Test.assertMessage(delegate.pending != null, "the next batch is scheduled, not run inline");
    Test.assertMessage(!Downloads.inBookIndex(DeleteFixtures.BOOK), "un-indexed before any audio goes");
    Test.assertEqual(DeleteFixtures.list().size(), 1);
    Test.assertEqual(delegate.completed, 0);

    delegate.drain();
    var expected = (300 + WatchShelfSyncDelegate.DELETE_BATCH - 1) / WatchShelfSyncDelegate.DELETE_BATCH;
    Test.assertEqual(delegate.batches, expected);
    for (var i = 1; i < delegate.percents.size(); ++i) {
        Test.assertMessage(delegate.percents[i] >= delegate.percents[i - 1], "progress never goes back");
    }
    Test.assertEqual(delegate.lastPct, 100);
    Test.assertEqual(DeleteFixtures.left(DeleteFixtures.BOOK), 0);
    Test.assertMessage(BookStore.get(DeleteFixtures.BOOK) == null, "metadata dropped");
    Test.assertMessage(Progress.get(DeleteFixtures.BOOK) == null, "saved progress dropped");
    Test.assertEqual(DeleteFixtures.list().size(), 0);
    Test.assertEqual(delegate.completed, 1);
    DeleteFixtures.clear();
    return true;
}

// A stop or crash mid-delete must leave a book the next sync can finish: the
// remaining pages stay contiguous and the book stays on DELETE_LIST.
(:test)
function deleteInterruptedMidwayResumesNextSync(logger) {
    DeleteFixtures.clear();
    DeleteFixtures.downloaded(DeleteFixtures.BOOK, 300, 0);
    DeleteFixtures.queue([DeleteFixtures.BOOK]);
    var delegate = new DeleteHarness();
    delegate.onStartSync();
    delegate.pump();
    var stale = delegate.pending;
    delegate.onStopSync();
    Test.assertEqual(delegate.completed, 1);
    var left = DeleteFixtures.left(DeleteFixtures.BOOK);
    Test.assertEqual(left, 300 - (2 * WatchShelfSyncDelegate.DELETE_BATCH));
    stale.invoke();   // a timer that fires after the stop does nothing
    Test.assertEqual(DeleteFixtures.left(DeleteFixtures.BOOK), left);
    Test.assertEqual(DeleteFixtures.list().size(), 1);
    Test.assertMessage(!Downloads.inBookIndex(DeleteFixtures.BOOK), "still hidden while half deleted");

    delegate = new DeleteHarness();
    delegate.onStartSync();
    delegate.drain();
    Test.assertEqual(DeleteFixtures.left(DeleteFixtures.BOOK), 0);
    Test.assertMessage(BookStore.get(DeleteFixtures.BOOK) == null, "finished on the next sync");
    Test.assertEqual(DeleteFixtures.list().size(), 0);
    Test.assertEqual(delegate.completed, 1);
    DeleteFixtures.clear();
    return true;
}

// If no Timer can be created the delete still finishes, in one event as before.
(:test)
function deleteWithoutATimerStillFinishes(logger) {
    DeleteFixtures.clear();
    DeleteFixtures.downloaded(DeleteFixtures.BOOK, 300, 0);
    DeleteFixtures.queue([DeleteFixtures.BOOK]);
    var delegate = new DeleteHarness();
    delegate.defer = false;
    delegate.onStartSync();
    Test.assertEqual(DeleteFixtures.left(DeleteFixtures.BOOK), 0);
    Test.assertEqual(DeleteFixtures.list().size(), 0);
    Test.assertEqual(delegate.completed, 1);
    DeleteFixtures.clear();
    return true;
}

(:test)
function deleteClearsBothSpeedsAndSeveralBooks(logger) {
    DeleteFixtures.clear();
    DeleteFixtures.downloaded(DeleteFixtures.BOOK, 260, 30);
    // A book with metadata but no audio still has to leave the list.
    BookStore.ensureMeta(DeleteFixtures.OTHER, "Empty", "Author", [180], 0, 100);
    BookStore.addToIndex(DeleteFixtures.OTHER);
    DeleteFixtures.queue([DeleteFixtures.BOOK, DeleteFixtures.OTHER]);
    var delegate = new DeleteHarness();
    delegate.onStartSync();
    delegate.drain();
    Test.assertEqual(DeleteFixtures.left(DeleteFixtures.BOOK), 0);
    Test.assertMessage(BookStore.get(DeleteFixtures.BOOK) == null, "first book gone");
    Test.assertMessage(BookStore.get(DeleteFixtures.OTHER) == null, "empty book gone");
    Test.assertMessage(!Downloads.inBookIndex(DeleteFixtures.OTHER), "empty book un-indexed");
    Test.assertEqual(DeleteFixtures.list().size(), 0);
    Test.assertEqual(delegate.lastPct, 100);
    Test.assertEqual(delegate.completed, 1);
    DeleteFixtures.clear();
    return true;
}

// A delete queued from the menu while batches run is left for the next sync,
// not dropped, exactly as before batching.
(:test)
function deleteQueuedMidwayIsKeptForTheNextSync(logger) {
    DeleteFixtures.clear();
    DeleteFixtures.downloaded(DeleteFixtures.BOOK, 60, 0);
    DeleteFixtures.downloaded(DeleteFixtures.OTHER, 10, 0);
    DeleteFixtures.queue([DeleteFixtures.BOOK]);
    var delegate = new DeleteHarness();
    delegate.onStartSync();
    DeleteFixtures.queue([DeleteFixtures.BOOK, DeleteFixtures.OTHER]);
    delegate.drain();
    var list = DeleteFixtures.list();
    Test.assertEqual(list.size(), 1);
    Test.assertEqual(list[0], DeleteFixtures.OTHER);
    Test.assertEqual(DeleteFixtures.left(DeleteFixtures.OTHER), 10);
    DeleteFixtures.clear();
    return true;
}

// Re-queued from the menu part-way: the sync stops deleting it.
(:test)
function deleteStopsWhenTheBookIsQueuedAgain(logger) {
    DeleteFixtures.clear();
    DeleteFixtures.downloaded(DeleteFixtures.BOOK, 60, 0);
    DeleteFixtures.queue([DeleteFixtures.BOOK]);
    var delegate = new DeleteHarness();
    delegate.onStartSync();
    DeleteFixtures.queue([]);
    delegate.drain();
    Test.assertEqual(DeleteFixtures.left(DeleteFixtures.BOOK), 60 - WatchShelfSyncDelegate.DELETE_BATCH);
    Test.assertMessage(BookStore.get(DeleteFixtures.BOOK) != null, "records kept for the new download");
    Test.assertEqual(delegate.completed, 1);
    DeleteFixtures.clear();
    return true;
}

(:test)
function bookStoreDropSomeTakesFromTheEnd(logger) {
    DeleteFixtures.clear();
    DeleteFixtures.downloaded(DeleteFixtures.BOOK, 260, 5);
    // The parked speed goes first, then the last page, keeping 0..m contiguous.
    // What is evicted must be exactly what is cut from the records: anything
    // else leaves records for audio that is gone and audio with no record.
    BookStore.evicted = [];
    Test.assertEqual(BookStore.dropSome(DeleteFixtures.BOOK, 8), 8);
    var gone = BookStore.evicted;
    BookStore.evicted = null;
    Test.assertEqual(gone.size(), 8);
    for (var i = 0; i < 5; ++i) { Test.assertEqual(gone[i], "__ws_del_ref_0_" + i); }
    Test.assertEqual(gone[5], "__ws_del_ref_1_1");
    Test.assertEqual(gone[7], "__ws_del_ref_1_3");
    Test.assertEqual(BookStore.countFor(DeleteFixtures.BOOK, BookStore.SLOT_ALT), 0);
    Test.assertEqual(BookStore.countFor(DeleteFixtures.BOOK, BookStore.SLOT_PRIMARY), 257);
    var page1 = Application.Storage.getValue(BookStore.pageKeyFor(DeleteFixtures.BOOK, BookStore.SLOT_PRIMARY, 1));
    Test.assertEqual(page1.size(), 1);
    Test.assertEqual(page1[0], "__ws_del_ref_1_0");
    Test.assertEqual(BookStore.dropSome(DeleteFixtures.BOOK, 8), 8);
    Test.assertMessage(Application.Storage.getValue(BookStore.pageKeyFor(DeleteFixtures.BOOK,
        BookStore.SLOT_PRIMARY, 1)) == null, "emptied page removed");
    Test.assertEqual(BookStore.countFor(DeleteFixtures.BOOK, BookStore.SLOT_PRIMARY), 249);
    Test.assertEqual(BookStore.dropSome(DeleteFixtures.BOOK, 1000), 249);
    Test.assertEqual(BookStore.dropSome(DeleteFixtures.BOOK, 8), 0);
    DeleteFixtures.clear();
    return true;
}
