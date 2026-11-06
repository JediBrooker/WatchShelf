using Toybox.Application;
using Toybox.Test;

// Issue #44 (b42 report): one failed chunk used to delete a manual book's whole
// download job. The partial stayed playable, but "Sync now" then had nothing to
// continue, so reaching the end of the downloaded audio meant re-selecting the
// book. Real callback chains and Storage run below; only transport is replaced.
(:test)
module SyncResumeFixtures {
    // 300s => three chunks: 0-15, 15-195, 195-300.
    function queueManual() {
        PodcastFixtures.clear();
        Test.assertMessage(Downloads.queue(PodcastFixtures.MANUAL, 100,
            PodcastFixtures.files(), false) == null, "manual queued");
    }
    function job() { return JobStore.get(PodcastFixtures.MANUAL); }
    // Exhaust the in-run retries for the chunk currently in flight.
    function failChunk(delegate, code) {
        for (var i = 0; i <= WatchShelfSyncDelegate.CHUNK_RETRIES; ++i) {
            delegate.callback.invoke(code, null);
        }
    }
}

(:test)
function syncDroppedConnectionKeepsManualJobResumable(logger) {
    SyncResumeFixtures.queueManual();
    var delegate = new PodcastDelegateHarness();
    delegate.onStartSync();
    delegate.callback.invoke(200, new PodcastFakeAudio());
    Test.assertEqual(SyncResumeFixtures.job()["done"], 1);

    SyncResumeFixtures.failChunk(delegate, -1004);
    var job = SyncResumeFixtures.job();
    Test.assertMessage(job != null, "a dropped connection must not cancel the download");
    Test.assertEqual(job["done"], 1);
    Test.assertMessage(job["retryAt"] > Progress.nowSec(), "failed job is paused");
    Test.assertMessage(!delegate.isSyncNeeded(), "firmware polling cannot spin the failed transfer");
    Test.assertEqual(BookStore.count(PodcastFixtures.MANUAL), 1);
    Test.assertMessage(Downloads.inBookIndex(PodcastFixtures.MANUAL), "partial stays playable");
    Test.assertMessage(Application.Storage.getValue(Store.LAST_SYNC_ERROR) != null, "failure is diagnosable");

    // The sync still flushes progress and ends exactly once.
    delegate.progressWorker.respond(200, {});
    Test.assertEqual(delegate.completed, 1);

    // Any later sync, with no re-selection, carries on from the same chunk and
    // a success clears the pause.
    delegate = new PodcastDelegateHarness();
    delegate.onStartSync();
    Test.assertEqual(delegate.audio, 1);
    Test.assertMessage(delegate.lastUrl.find("start=15") != null, "resumes at the failed chunk");
    delegate.callback.invoke(200, new PodcastFakeAudio());
    job = SyncResumeFixtures.job();
    Test.assertEqual(job["done"], 2);
    Test.assertMessage(job["retryAt"] == null, "success clears the pause");
    delegate.onStopSync();
    PodcastFixtures.clear();
    return true;
}

(:test)
function syncRetriesAChunkBeforeGivingUp(logger) {
    SyncResumeFixtures.queueManual();
    var delegate = new PodcastDelegateHarness();
    delegate.onStartSync();
    // Each chunk gets its own allowance: a success resets the count.
    for (var round = 0; round < 2; ++round) {
        for (var i = 0; i < WatchShelfSyncDelegate.CHUNK_RETRIES; ++i) {
            delegate.callback.invoke(524, null);
            Test.assertEqual(SyncResumeFixtures.job()["done"], round);
        }
        delegate.callback.invoke(200, new PodcastFakeAudio());
        Test.assertEqual(SyncResumeFixtures.job()["done"], round + 1);
    }
    Test.assertMessage(Application.Storage.getValue(Store.LAST_SYNC_ERROR) == null, "a recovered blip is not an error");
    Test.assertMessage(SyncResumeFixtures.job()["retryAt"] == null, "a recovered blip does not pause the job");
    delegate.onStopSync();
    PodcastFixtures.clear();
    return true;
}

(:test)
function syncFailedBookDoesNotBlockTheNextOne(logger) {
    SyncResumeFixtures.queueManual();
    Test.assertMessage(Downloads.queue(PodcastFixtures.TWO, 100,
        PodcastFixtures.files(), false) == null, "second manual queued");
    var delegate = new PodcastDelegateHarness();
    delegate.onStartSync();
    SyncResumeFixtures.failChunk(delegate, 502);
    Test.assertMessage(delegate.lastUrl.find(PodcastFixtures.TWO) != null, "next book still runs");
    delegate.callback.invoke(200, new PodcastFakeAudio());
    Test.assertEqual(JobStore.get(PodcastFixtures.TWO)["done"], 1);
    Test.assertEqual(SyncResumeFixtures.job()["done"], 0);
    delegate.onStopSync();
    PodcastFixtures.clear();
    return true;
}

(:test)
function syncActionableFailureStillCancelsTheJob(logger) {
    var codes = [404, 403, 400, -1000, -1002, -1005];
    for (var i = 0; i < codes.size(); ++i) {
        SyncResumeFixtures.queueManual();
        var delegate = new PodcastDelegateHarness();
        delegate.onStartSync();
        delegate.callback.invoke(codes[i], null);
        Test.assertEqual(delegate.audio, 1);
        Test.assertMessage(SyncResumeFixtures.job() == null, "retrying cannot help code " + codes[i]);
        // Nothing is indexed, so the progress exchange has nothing to request.
        Test.assertEqual(delegate.completed, 1);
    }
    PodcastFixtures.clear();
    return true;
}

(:test)
function syncStopNeverDamagesTheJob(logger) {
    SyncResumeFixtures.queueManual();
    var delegate = new PodcastDelegateHarness();
    delegate.cancelReports = true;
    delegate.onStartSync();
    delegate.onStopSync();
    Test.assertEqual(delegate.audio, 1);
    Test.assertEqual(delegate.completed, 1);
    Test.assertMessage(SyncResumeFixtures.job()["retryAt"] == null, "a stop is not a failure");
    Test.assertMessage(Application.Storage.getValue(Store.LAST_SYNC_ERROR) == null, "a stop reports no error");
    PodcastFixtures.clear();
    return true;
}

(:test)
function syncResumeReportsProgressAlreadyMade(logger) {
    SyncResumeFixtures.queueManual();
    var job = SyncResumeFixtures.job();
    job["done"] = 1;
    JobStore.put(PodcastFixtures.MANUAL, job);
    var delegate = new PodcastDelegateHarness();
    delegate.onStartSync();
    Test.assertEqual(delegate.lastPct, 33);
    delegate.onStopSync();
    PodcastFixtures.clear();
    return true;
}

(:test)
function downloadFailureClassification(logger) {
    var transient = [-1004, -1003, -300, -400, -104, -5, -3, -2, 200, 401, 408, 429, 500, 502, 503, 524];
    for (var i = 0; i < transient.size(); ++i) {
        Test.assertMessage(Errors.downloadRecoverable(transient[i]), "recoverable " + transient[i]);
    }
    var actionable = [400, 403, 404, 410, -1000, -1001, -1002, -1005, -402, -403];
    for (var i = 0; i < actionable.size(); ++i) {
        Test.assertMessage(!Errors.downloadRecoverable(actionable[i]), "actionable " + actionable[i]);
    }
    return true;
}
