using Toybox.Application;
using Toybox.Test;

// These harnesses replace only the transport boundary. Real callback chains,
// persistent state, queue validation, progress merge and completion run below.
(:test)
class PodcastEngineHarness extends PodcastSync {
    var power = true;
    var callback;
    var requests = 0;
    var requestedItem;
    var completed = 0;
    function initialize() { PodcastSync.initialize(); }
    function charging() { return power; }
    function requestCandidates(settings, cb) { callback = cb; requests += 1; requestedItem = settings["id"]; }
    function requestFiles(itemId, cb) { callback = cb; requests += 1; requestedItem = itemId; }
    function done() { completed += 1; }
    function respond(code, data) { var cb = callback; callback = null; cb.invoke(code, data); }
}
(:test)
class PodcastProgressHarness extends ProgressSync {
    var callback;
    var pulls = 0;
    var pushes = 0;
    var completed = 0;
    function initialize() { ProgressSync.initialize(); }
    function requestPull(id, cb) { callback = cb; pulls += 1; }
    function requestPush(id, pos, duration, ts, finished, cb) { callback = cb; pushes += 1; }
    function done() { completed += 1; }
    function respond(code, data) { var cb = callback; callback = null; cb.invoke(code, data); }
}
(:test)
class PodcastDelegateHarness extends WatchShelfSyncDelegate {
    var power = false;
    var completed = 0;
    var audio = 0;
    var discarded = 0;
    var callback;
    var progressWorker;
    var lastUrl;
    function initialize() { WatchShelfSyncDelegate.initialize(); }
    function charging() { return power; }
    function createProgressSync() { progressWorker = new PodcastProgressHarness(); return progressWorker; }
    function requestAudio(url, options, cb) { audio += 1; callback = cb; lastUrl = url; }
    function notifyComplete(error) { completed += 1; }
    function discardAudio(refId) { discarded += 1; }
    function sweepOrphans() {}
    function onOpDone() {}
}
(:test)
class PodcastFakeAudio {
    function getId() { return "__podcast_fake_ref__"; }
}
(:test)
module PodcastFixtures {
    const SHOW = "__ws_pod_show";
    const ONE = "__ws_pod_show__one";
    const TWO = "__ws_pod_show__two";
    const MANUAL = "__ws_pod_manual";
    function clear() {
        var ids = [ONE, TWO, MANUAL];
        for (var i = 0; i < ids.size(); ++i) {
            JobStore.remove(ids[i]); BookStore.removeFromIndex(ids[i]);
            BookStore.deleteBook(ids[i]); Progress.remove(ids[i]);
            Application.Storage.deleteValue(PodcastSettings.ownerKey(ids[i]));
        }
        Application.Storage.deleteValue(PodcastSettings.key(SHOW));
        Application.Storage.deleteValue(PodcastSettings.INDEX);
        Application.Storage.deleteValue(PodcastSchedule.KEY);
        Application.Storage.deleteValue(PodcastRetention.KEY);
        Application.Storage.deleteValue(Store.FORCE_SYNC);
        Application.Storage.deleteValue(Store.DELETE_LIST);
        Application.Storage.deleteValue(Store.LAST_SYNC_ERROR);
        Application.Storage.deleteValue("podcastStatus");
    }
    function show(limit, remove) {
        Test.assertMessage(PodcastSettings.save(SHOW, "Test show", true, limit, "newest", remove), "enabled fixture");
    }
    function own(id) { Test.assertMessage(PodcastSettings.claim(id, SHOW, PodcastSettings.get(SHOW)["generation"]), "claimed"); }
    function files() { return { "title" => "Episode", "author" => "Show", "files" => [{ "ino" => "1", "duration" => 300 }], "progress" => null }; }
    function row(id) { return { "id" => id, "title" => "Episode", "author" => "Show", "publishedAt" => 100, "progress" => null }; }
    function candidates(rows) { return { "version" => 1, "checkedAtSec" => 100, "show" => { "id" => SHOW }, "episodes" => rows }; }
    function autoJob(id) { own(id); Test.assertMessage(Downloads.queue(id, 100, files(), true) == null, "queued automatic fixture"); }
    function downloaded(id, automatic) {
        if (automatic) { own(id); }
        BookStore.ensureMeta(id, "Episode", "Show", [300], 0, 100);
        BookStore.saveChunk(id, 0, "__podcast_fixture_ref__"); BookStore.addToIndex(id);
    }
    function remote(pos, ts, finished) { return { "currentTime" => pos, "lastUpdate" => ts, "isFinished" => finished, "duration" => 300 }; }
}

(:test)
function podcastScheduleIsBoundedAndCrashSafe(logger) {
    PodcastFixtures.clear(); PodcastFixtures.show(1, false);
    Test.assertMessage(PodcastSchedule.due(100), "first check is due");
    PodcastSchedule.begin(100);
    Test.assertMessage(!PodcastSchedule.due(101), "attempt immediately persists cooldown");
    Test.assertMessage(PodcastSchedule.due(3700), "failed attempt retries after one hour");
    PodcastSchedule.success(200);
    Test.assertEqual(PodcastSchedule.state()["attempt"], 100);
    Test.assertEqual(PodcastSchedule.state()["success"], 200);
    Test.assertMessage(!PodcastSchedule.due(21799), "six hour success");
    Test.assertMessage(PodcastSchedule.due(21800), "six hours elapsed");
    Test.assertMessage(PodcastSchedule.due(-1000), "backwards clock cannot pin deadline indefinitely");
    Test.assertMessage(!PodcastSchedule.discoveryNeeded(false, false, 99999), "off power skips discovery");
    Test.assertMessage(PodcastSchedule.discoveryNeeded(true, false, 201), "explicit sync bypasses schedule and power");
    PodcastFixtures.clear(); return true;
}

(:test)
function podcastDiscoveryQueuesAndHonorsPerShowLimit(logger) {
    PodcastFixtures.clear(); PodcastFixtures.show(2, false);
    PodcastFixtures.autoJob(PodcastFixtures.ONE);
    var worker = new PodcastEngineHarness(); worker.start(false, {}, worker.method(:done));
    Test.assertMessage(PodcastSchedule.state()["attempt"] != null, "attempt stored before transport");
    worker.respond(200, PodcastFixtures.candidates([PodcastFixtures.row(PodcastFixtures.TWO)]));
    Test.assertEqual(worker.requestedItem, PodcastFixtures.TWO);
    worker.respond(200, PodcastFixtures.files());
    Test.assertMessage(JobStore.get(PodcastFixtures.TWO) != null, "candidate queued");
    Test.assertEqual(JobStore.get(PodcastFixtures.TWO)["autoShow"], PodcastFixtures.SHOW);
    Test.assertEqual(worker.completed, 1);
    Test.assertMessage(PodcastSchedule.state()["success"] != null, "successful discovery fresh");
    // Lowering the limit does not delete an unfinished job.
    PodcastFixtures.show(1, false);
    Test.assertMessage(JobStore.get(PodcastFixtures.ONE) != null && JobStore.get(PodcastFixtures.TWO) != null, "lowering limit preserves unfinished jobs");
    PodcastFixtures.clear(); return true;
}

(:test)
function podcastDiscoveryDoesNotDisplaceUnfinishedOrAdoptManual(logger) {
    PodcastFixtures.clear(); PodcastFixtures.show(1, false);
    PodcastFixtures.autoJob(PodcastFixtures.ONE);
    var worker = new PodcastEngineHarness(); worker.start(false, {}, worker.method(:done));
    worker.respond(200, PodcastFixtures.candidates([PodcastFixtures.row(PodcastFixtures.TWO)]));
    Test.assertEqual(worker.requests, 1);
    Test.assertMessage(JobStore.get(PodcastFixtures.TWO) == null, "existing unfinished consumes quota");
    JobStore.remove(PodcastFixtures.ONE);
    PodcastFixtures.downloaded(PodcastFixtures.TWO, false);
    worker = new PodcastEngineHarness(); worker.start(true, {}, worker.method(:done));
    worker.respond(200, PodcastFixtures.candidates([PodcastFixtures.row(PodcastFixtures.TWO)]));
    Test.assertMessage(PodcastSettings.owner(PodcastFixtures.TWO) == null, "legacy/manual content never automatically owned");
    PodcastFixtures.clear(); return true;
}

(:test)
function podcastStaleSettingsAndClearCannotRequeue(logger) {
    PodcastFixtures.clear(); PodcastFixtures.show(1, false);
    var worker = new PodcastEngineHarness(); worker.start(false, {}, worker.method(:done));
    worker.respond(200, PodcastFixtures.candidates([PodcastFixtures.row(PodcastFixtures.ONE)]));
    PodcastSettings.save(PodcastFixtures.SHOW, "Show", false, 1, "newest", false);
    worker.respond(200, PodcastFixtures.files());
    Test.assertMessage(JobStore.get(PodcastFixtures.ONE) == null, "disable while files in flight");
    Test.assertEqual(worker.completed, 1);
    PodcastFixtures.show(1, false);
    worker = new PodcastEngineHarness(); worker.start(true, {}, worker.method(:done));
    worker.respond(200, PodcastFixtures.candidates([PodcastFixtures.row(PodcastFixtures.ONE)]));
    JobStore.clearAll(); worker.respond(200, PodcastFixtures.files());
    Test.assertMessage(JobStore.get(PodcastFixtures.ONE) == null, "clear queue invalidates pending discovery callback");
    PodcastFixtures.clear(); return true;
}

(:test)
function podcastMalformedOldSidecarAndCancelAreSafe(logger) {
    PodcastFixtures.clear(); PodcastFixtures.show(2, false);
    var worker = new PodcastEngineHarness(); worker.start(false, {}, worker.method(:done));
    worker.respond(200, PodcastFixtures.candidates([PodcastFixtures.row(PodcastFixtures.ONE), PodcastFixtures.row(PodcastFixtures.ONE)]));
    Test.assertEqual(worker.requests, 1);
    Test.assertMessage(PodcastSchedule.state()["success"] == null, "malformed duplicate rows not successful");
    worker = new PodcastEngineHarness(); worker.start(true, {}, worker.method(:done));
    worker.respond(404, {});
    Test.assertEqual(Application.Storage.getValue("podcastStatus"), "Update sidecar");
    worker = new PodcastEngineHarness(); worker.start(true, {}, worker.method(:done));
    worker.cancel(); worker.respond(200, PodcastFixtures.candidates([PodcastFixtures.row(PodcastFixtures.ONE)]));
    Test.assertEqual(worker.requests, 1); Test.assertEqual(worker.completed, 0);
    Test.assertMessage(JobStore.get(PodcastFixtures.ONE) == null, "cancelled callback cannot restart work");
    PodcastFixtures.clear(); return true;
}

(:test)
function podcastFinishedDirtyNeverDownloadsAgain(logger) {
    PodcastFixtures.clear(); PodcastFixtures.show(1, false);
    Progress.record(PodcastFixtures.ONE, 300, 100, true);
    var worker = new PodcastEngineHarness(); worker.start(false, {}, worker.method(:done));
    worker.respond(200, PodcastFixtures.candidates([PodcastFixtures.row(PodcastFixtures.ONE)]));
    Test.assertEqual(worker.requests, 1);
    Test.assertMessage(Progress.get(PodcastFixtures.ONE)[2], "completion stays dirty");
    Test.assertMessage(JobStore.get(PodcastFixtures.ONE) == null, "server stale candidate cannot recreate finished local");
    PodcastFixtures.clear(); return true;
}

(:test)
function podcastProgressRequiresSuccessfulPullAndExactPush(logger) {
    PodcastFixtures.clear(); PodcastFixtures.show(1, true);
    PodcastFixtures.downloaded(PodcastFixtures.ONE, true);
    Progress.record(PodcastFixtures.ONE, 300, 100, true);
    var exchange = new PodcastProgressHarness(); exchange.start(exchange.method(:done));
    exchange.respond(500, null); exchange.respond(200, {});
    Test.assertMessage(exchange.acknowledgements()[PodcastFixtures.ONE] == null, "failed pull cannot grant prune even after push");
    Test.assertEqual(exchange.completed, 1);
    Progress.record(PodcastFixtures.ONE, 300, 101, true);
    exchange = new PodcastProgressHarness(); exchange.start(exchange.method(:done));
    exchange.respond(200, PodcastFixtures.remote(0, 90, false));
    // A concurrent rewind remains dirty despite the older successful response.
    Progress.record(PodcastFixtures.ONE, 0, 102, false);
    exchange.respond(200, {});
    Test.assertMessage(exchange.acknowledgements()[PodcastFixtures.ONE] == null, "rewind invalidates exact acknowledgement");
    Test.assertMessage(Progress.get(PodcastFixtures.ONE)[2], "rewind remains dirty");
    PodcastFixtures.clear(); return true;
}

(:test)
function podcastRetentionRequiresCurrentOwnershipAndCleanAck(logger) {
    PodcastFixtures.clear(); PodcastFixtures.show(1, true);
    PodcastFixtures.downloaded(PodcastFixtures.ONE, true);
    var gen = PodcastSettings.get(PodcastFixtures.SHOW)["generation"];
    Progress.record(PodcastFixtures.ONE, 300, 100, true);
    var ack = [300, 100, true];
    Test.assertMessage(!PodcastRetention.prune(PodcastFixtures.ONE, PodcastFixtures.SHOW, gen, ack), "dirty finish cannot prune");
    Progress.markClean(PodcastFixtures.ONE, 100, 300, true);
    Test.assertMessage(!PodcastRetention.prune(PodcastFixtures.ONE, PodcastFixtures.SHOW, gen, null), "missing ack cannot prune");
    PodcastSettings.release(PodcastFixtures.ONE);
    Test.assertMessage(!PodcastRetention.prune(PodcastFixtures.ONE, PodcastFixtures.SHOW, gen, ack), "Keep on watch removes deletion authority");
    Test.assertMessage(BookStore.count(PodcastFixtures.ONE) > 0, "audio retained");
    PodcastFixtures.clear(); return true;
}

(:test)
function podcastRetentionCrashRecordSurvivesUnindex(logger) {
    PodcastFixtures.clear(); PodcastFixtures.show(1, true);
    PodcastFixtures.downloaded(PodcastFixtures.ONE, true);
    Progress.record(PodcastFixtures.ONE, 300, 100, true);
    Progress.markClean(PodcastFixtures.ONE, 100, 300, true);
    var gen = PodcastSettings.get(PodcastFixtures.SHOW)["generation"];
    Application.Storage.setValue(PodcastRetention.KEY, { "item" => PodcastFixtures.ONE,
        "show" => PodcastFixtures.SHOW, "generation" => gen, "ack" => [300,100,true] });
    BookStore.removeFromIndex(PodcastFixtures.ONE);
    var exchange = new PodcastProgressHarness(); exchange.start(exchange.method(:done));
    Test.assertEqual(exchange.pulls, 1);
    exchange.respond(200, PodcastFixtures.remote(300, 100, true));
    Test.assertMessage(PodcastRetention.prune(PodcastFixtures.ONE, PodcastFixtures.SHOW, gen,
        exchange.acknowledgements()[PodcastFixtures.ONE]), "fresh recovery acknowledgement completes deletion");
    Test.assertMessage(BookStore.get(PodcastFixtures.ONE) == null, "audio metadata removed");
    Test.assertMessage(Progress.get(PodcastFixtures.ONE) == null, "only acknowledged clean progress removed after deletion");
    Test.assertMessage(PodcastRetention.pending() == null, "bounded recovery record cleared");
    PodcastFixtures.clear(); return true;
}

(:test)
function podcastDelegateGatesAutomaticAndHonorsManual(logger) {
    PodcastFixtures.clear(); PodcastFixtures.show(1, false);
    PodcastFixtures.autoJob(PodcastFixtures.ONE);
    PodcastSchedule.success(Progress.nowSec());
    var delegate = new PodcastDelegateHarness();
    Test.assertMessage(!delegate.isSyncNeeded(), "auto job off charger cannot request sync");
    Test.assertMessage(Downloads.queue(PodcastFixtures.MANUAL, 100, PodcastFixtures.files(), false) == null, "manual queue");
    Test.assertMessage(delegate.isSyncNeeded(), "manual job still requests sync");
    delegate.onStartSync();
    Test.assertEqual(delegate.audio, 1);
    Test.assertMessage(delegate.lastUrl.find(PodcastFixtures.MANUAL) != null, "manual bypasses parked automatic job");
    var late = delegate.callback;
    delegate.onStopSync(); delegate.onStopSync(); late.invoke(500, null);
    Test.assertEqual(delegate.completed, 1); Test.assertEqual(delegate.audio, 1);
    Test.assertMessage(JobStore.get(PodcastFixtures.ONE) != null, "auto remains resumable");
    PodcastFixtures.clear(); return true;
}

(:test)
function podcastAutoFailureBackoffAndUnplugPause(logger) {
    PodcastFixtures.clear(); PodcastFixtures.show(1, false);
    PodcastFixtures.autoJob(PodcastFixtures.ONE); PodcastSchedule.success(Progress.nowSec());
    var delegate = new PodcastDelegateHarness(); delegate.power = true;
    delegate.onStartSync(); delegate.callback.invoke(500, null);
    Test.assertMessage(JobStore.get(PodcastFixtures.ONE)["retryAt"] > Progress.nowSec(), "automatic failed job remains with backoff");
    Test.assertMessage(!delegate.isSyncNeeded(), "repeated firmware poll cannot spin failed transfer");
    var job = JobStore.get(PodcastFixtures.ONE); job.remove("retryAt"); JobStore.put(PodcastFixtures.ONE, job);
    delegate = new PodcastDelegateHarness(); delegate.power = true; delegate.onStartSync();
    delegate.power = false; delegate.callback.invoke(200, new PodcastFakeAudio());
    Test.assertEqual(delegate.audio, 1);
    Test.assertEqual(JobStore.get(PodcastFixtures.ONE)["done"], 0);
    Test.assertEqual(delegate.discarded, 1);
    delegate.onStopSync();
    // Explicit sync consumes FORCE_SYNC and can resume while off charger.
    Application.Storage.setValue(Store.FORCE_SYNC, true);
    delegate = new PodcastDelegateHarness(); delegate.onStartSync();
    Test.assertEqual(delegate.audio, 1);
    Test.assertMessage(Application.Storage.getValue(Store.FORCE_SYNC) == null, "force is consumed once");
    delegate.onStopSync(); PodcastFixtures.clear(); return true;
}

(:test)
function podcastSharedQueueBoundsAndPreservesResume(logger) {
    PodcastFixtures.clear();
    var data = PodcastFixtures.files(); data["files"][0]["duration"] = 999999999;
    Test.assertMessage(Downloads.queue(PodcastFixtures.MANUAL, 100, data, false) != null, "hostile duration cannot create unbounded chunk loop");
    data = PodcastFixtures.files(); data["files"][0]["ino"] = {};
    Test.assertMessage(Downloads.queue(PodcastFixtures.MANUAL, 100, data, false) != null, "invalid inode rejected before storage");
    data = PodcastFixtures.files();
    Test.assertMessage(Downloads.queue(PodcastFixtures.MANUAL, 100, data, false) == null, "manual initial job");
    var oldGen = JobStore.get(PodcastFixtures.MANUAL)["gen"];
    BookStore.ensureMeta(PodcastFixtures.MANUAL, "Episode", "Show", [300], 0, 100);
    BookStore.saveChunk(PodcastFixtures.MANUAL, 0, "__podcast_fixture_ref__");
    BookStore.addToIndex(PodcastFixtures.MANUAL);
    Test.assertMessage(Downloads.queue(PodcastFixtures.MANUAL, 100, data, false) == null, "manual interrupted retry");
    Test.assertEqual(JobStore.get(PodcastFixtures.MANUAL)["done"], 1);
    Test.assertEqual(JobStore.get(PodcastFixtures.MANUAL)["gen"], oldGen + 1);
    PodcastFixtures.clear(); return true;
}

(:test)
function podcastLongManualTailFitsAndPlaysWithoutWholeBookArrays(logger) {
    PodcastFixtures.clear();
    var data = PodcastFixtures.files(); data["files"][0]["duration"] = 900000000;
    Progress.record(PodcastFixtures.MANUAL, 899999800, 100, false);
    Test.assertMessage(Downloads.queue(PodcastFixtures.MANUAL, 100, data, false) == null,
        "tiny remaining tail of very long source fits chunk cap");
    var job = JobStore.get(PodcastFixtures.MANUAL);
    Test.assertMessage(Chunks.total(job["durs"]) - job["base"] < 5, "only remaining tail queued");
    BookStore.ensureMeta(PodcastFixtures.MANUAL, "Long", "Show", job["durs"], job["base"], 100);
    BookStore.saveChunk(PodcastFixtures.MANUAL, job["base"], "__podcast_fixture_ref__");
    BookStore.addToIndex(PodcastFixtures.MANUAL);
    var it = new ContentIterator({ "item" => PodcastFixtures.MANUAL, "mode" => "start" });
    var c = Chunks.at(job["durs"], job["base"]);
    Test.assertEqual(it.size(), 1); Test.assertEqual(it.startAt(0), c["start"]);
    var lookup = {}; BookStore.addLookup(PodcastFixtures.MANUAL, 0, lookup);
    Test.assertEqual(lookup["__podcast_fixture_ref__"][1], c["start"]);
    PodcastFixtures.clear(); return true;
}

(:test)
function podcastRetentionCrashThenRewindRestoresRemainingAudio(logger) {
    PodcastFixtures.clear(); PodcastFixtures.show(1, true);
    PodcastFixtures.downloaded(PodcastFixtures.ONE, true);
    var gen = PodcastSettings.get(PodcastFixtures.SHOW)["generation"];
    Application.Storage.setValue(PodcastRetention.KEY, { "item" => PodcastFixtures.ONE,
        "show" => PodcastFixtures.SHOW, "generation" => gen, "ack" => [300,100,true] });
    BookStore.removeFromIndex(PodcastFixtures.ONE);
    Progress.record(PodcastFixtures.ONE, 20, 101, false);
    PodcastRetention.restoreIfInvalid();
    Test.assertMessage(PodcastRetention.pending() == null, "changed progress releases recovery journal");
    Test.assertMessage(Downloads.inBookIndex(PodcastFixtures.ONE), "surviving prefix visible again");
    Test.assertMessage(Progress.get(PodcastFixtures.ONE)[2], "offline rewind remains dirty");
    PodcastFixtures.clear(); return true;
}

(:test)
function podcastRequeueCannotReuseCancelledGeneration(logger) {
    PodcastFixtures.clear();
    Test.assertMessage(Downloads.queue(PodcastFixtures.MANUAL,100,PodcastFixtures.files(),false) == null, "first queue");
    var old = JobStore.get(PodcastFixtures.MANUAL)["gen"];
    JobStore.clearAll();
    Test.assertMessage(Downloads.queue(PodcastFixtures.MANUAL,100,PodcastFixtures.files(),false) == null, "requeue");
    Test.assertMessage(JobStore.get(PodcastFixtures.MANUAL)["gen"] > old, "cancel/requeue cannot accept stale chunk");
    PodcastFixtures.clear(); return true;
}

(:test)
function podcastAdoptClearRequeueRejectsOldAudioCallback(logger) {
    PodcastFixtures.clear(); PodcastFixtures.show(1, false);
    PodcastFixtures.autoJob(PodcastFixtures.ONE);
    PodcastSettings.adopt(PodcastFixtures.ONE);
    var delegate = new PodcastDelegateHarness(); delegate.onStartSync();
    var old = delegate.callback;
    JobStore.clearAll();
    Test.assertMessage(Downloads.queue(PodcastFixtures.ONE, 200, PodcastFixtures.files(), false) == null, "replacement speed queued");
    old.invoke(200, new PodcastFakeAudio());
    Test.assertEqual(delegate.discarded, 1);
    Test.assertEqual(delegate.audio, 2);
    Test.assertMessage(BookStore.get(PodcastFixtures.ONE) == null, "stale bytes never recorded under replacement speed");
    Test.assertEqual(JobStore.get(PodcastFixtures.ONE)["done"], 0);
    delegate.onStopSync(); PodcastFixtures.clear(); return true;
}

(:test)
function podcastDisabledLastShowRecoversJournalDuringOrdinarySync(logger) {
    PodcastFixtures.clear(); PodcastFixtures.show(1, true);
    PodcastFixtures.downloaded(PodcastFixtures.ONE, true);
    var gen = PodcastSettings.get(PodcastFixtures.SHOW)["generation"];
    Progress.record(PodcastFixtures.ONE, 300, 100, true);
    Progress.markClean(PodcastFixtures.ONE, 100, 300, true);
    Application.Storage.setValue(PodcastRetention.KEY, { "item" => PodcastFixtures.ONE,
        "show" => PodcastFixtures.SHOW, "generation" => gen, "ack" => [300,100,true] });
    BookStore.removeFromIndex(PodcastFixtures.ONE);
    PodcastSettings.save(PodcastFixtures.SHOW, "Show", false, 1, "newest", true);
    Test.assertEqual(PodcastSettings.list().size(), 0);
    var delegate = new PodcastDelegateHarness(); delegate.power = false;
    delegate.onStartSync();
    Test.assertMessage(PodcastRetention.pending() == null, "ordinary off-charge sync recovers journal");
    Test.assertMessage(Downloads.inBookIndex(PodcastFixtures.ONE), "disabled show surviving audio visible");
    Test.assertEqual(delegate.audio, 0);
    delegate.onStopSync(); PodcastFixtures.clear(); return true;
}

(:test)
function podcastQueueBoundsSerializedMetadataBeforeMutation(logger) {
    PodcastFixtures.clear();
    var longTitle = "";
    for (var i = 0; i < 250; ++i) { longTitle += "x"; }
    var data = { "title" => longTitle, "author" => longTitle, "files" => [], "progress" => null };
    for (var f = 0; f < JobStore.MAX_FILES; ++f) {
        data["files"].add({ "ino" => "123456789012345678901234", "duration" => 1 });
    }
    Test.assertMessage(Downloads.queue(PodcastFixtures.MANUAL,100,data,false) == null, "600 bounded inode records fit");
    Test.assertEqual(JobStore.get(PodcastFixtures.MANUAL)["inos"].size(), 600);
    Test.assertEqual(JobStore.get(PodcastFixtures.MANUAL)["title"].length(), 180);
    Test.assertEqual(JobStore.get(PodcastFixtures.MANUAL)["author"].length(), 180);
    var oldGen = JobStore.get(PodcastFixtures.MANUAL)["gen"];
    data["files"][0]["ino"] = "123456789012345678901234123456789012345678901234123456789012345678901234123456789012345678901234";
    Test.assertMessage(Downloads.queue(PodcastFixtures.MANUAL,200,data,false) != null, "96-byte inode rejected");
    Test.assertEqual(JobStore.get(PodcastFixtures.MANUAL)["gen"], oldGen);
    Test.assertEqual(JobStore.get(PodcastFixtures.MANUAL)["speed"], 100);
    data["files"][0]["ino"] = "123"; data["title"] = {};
    Test.assertMessage(Downloads.queue(PodcastFixtures.MANUAL,200,data,false) != null, "invalid metadata rejected");
    Test.assertEqual(JobStore.get(PodcastFixtures.MANUAL)["gen"], oldGen);
    PodcastFixtures.clear(); return true;
}

(:test)
function podcastAccountChangeRejectsInFlightAutomaticBytes(logger) {
    PodcastFixtures.clear(); PodcastFixtures.show(1, false);
    PodcastFixtures.autoJob(PodcastFixtures.ONE);
    var oldToken = Application.Storage.getValue(Store.TOKEN);
    var delegate = new PodcastDelegateHarness(); delegate.power = true; delegate.onStartSync();
    Application.Storage.setValue(Store.TOKEN, "__podcast_different_account__");
    delegate.callback.invoke(200, new PodcastFakeAudio());
    Test.assertEqual(delegate.discarded, 1);
    Test.assertMessage(BookStore.get(PodcastFixtures.ONE) == null, "old-account bytes never committed");
    Test.assertMessage(JobStore.get(PodcastFixtures.ONE) == null, "old-account automatic job cancelled");
    delegate.onStopSync();
    if (oldToken == null) { Application.Storage.deleteValue(Store.TOKEN); }
    else { Application.Storage.setValue(Store.TOKEN, oldToken); }
    PodcastSettings.ensureScope(); PodcastFixtures.clear(); return true;
}

(:test)
function podcastAutomaticIndexBudgetPreventsOwnershipAndQueueMutation(logger) {
    PodcastFixtures.clear(); PodcastFixtures.show(1, false);
    var previous = Application.Storage.getValue(Store.BOOK_INDEX);
    var ids = [];
    // Each composite ID has the shape/length of two UUID-like ABS identifiers.
    // No audio metadata is needed to prove the index itself is the constraint.
    var prefix = "12345678-1234-1234-1234-123456789012__12345678-1234-1234-1234-123456789";
    for (var i = 0; i < 300; ++i) { ids.add(prefix + i.toString()); }
    Application.Storage.setValue(Store.BOOK_INDEX, ids);
    Test.assertMessage(!Downloads.automaticIndexFits(PodcastFixtures.ONE), "realistic composite IDs exceed safe index budget before chunk cap");
    var worker = new PodcastEngineHarness(); worker.start(false, {}, worker.method(:done));
    worker.respond(200, PodcastFixtures.candidates([PodcastFixtures.row(PodcastFixtures.ONE)]));
    Test.assertEqual(worker.requests, 1);
    Test.assertMessage(PodcastSettings.owner(PodcastFixtures.ONE) == null, "capacity rejection happens before ownership claim");
    Test.assertMessage(JobStore.get(PodcastFixtures.ONE) == null, "capacity rejection leaves queue unchanged");
    Test.assertEqual(Application.Storage.getValue(Store.BOOK_INDEX).size(), 300);
    Test.assertEqual(Downloads.queue(PodcastFixtures.ONE,100,PodcastFixtures.files(),true), Rez.Strings.downloadsFull);
    if (previous == null) { Application.Storage.deleteValue(Store.BOOK_INDEX); }
    else { Application.Storage.setValue(Store.BOOK_INDEX, previous); }
    PodcastFixtures.clear(); return true;
}
