using Toybox.Application;
using Toybox.Test;

// Isolate the persisted indexes/account without deleting real watch state.
// Tests use no network and never allocate audio cache entries.
class PodcastSettingsTestState {
    private var mSaved;
    private var mKeys;
    function initialize() {
        mKeys = [PodcastSettings.INDEX, PodcastSettings.EPOCH, PodcastSettings.SCOPE,
            JobStore.INDEX, "jobGeneration", Store.BOOK_INDEX, Store.SERVER, Store.TOKEN];
        mSaved = {};
        for (var i = 0; i < mKeys.size(); ++i) {
            mSaved[mKeys[i]] = Application.Storage.getValue(mKeys[i]);
        }
        Application.Storage.setValue(JobStore.INDEX, []);
        Application.Storage.deleteValue("jobGeneration");
        Application.Storage.setValue(Store.BOOK_INDEX, []);
        Application.Storage.setValue(PodcastSettings.INDEX, []);
        Application.Storage.setValue(Store.SERVER, "https://podcast-tests.invalid");
        Application.Storage.setValue(Store.TOKEN, "podcast-test-account");
        PodcastSettings.ensureScope();
    }
    function restore() {
        for (var i = 0; i < 32; ++i) {
            var show = "__pod_show_" + i.toString();
            var episode = "__pod_episode_" + i.toString();
            Application.Storage.deleteValue(PodcastSettings.key(show));
            Application.Storage.deleteValue(PodcastSettings.ownerKey(episode));
            Application.Storage.deleteValue(JobStore.key(episode));
            if (BookStore.get(episode) != null) { BookStore.deleteBook(episode); }
        }
        for (var i = 0; i < mKeys.size(); ++i) {
            if (mSaved[mKeys[i]] == null) { Application.Storage.deleteValue(mKeys[i]); }
            else { Application.Storage.setValue(mKeys[i], mSaved[mKeys[i]]); }
        }
    }
}

(:test)
function podcastSettingsOptInAndBounds(logger) {
    var state = new PodcastSettingsTestState();
    var show = "__pod_show_0";
    var fresh = PodcastSettings.get(show);
    Test.assert(!fresh["enabled"]);
    Test.assert(!fresh["removeFinished"]);
    Test.assertEqual(fresh["limit"], 1);
    Test.assertEqual(fresh["order"], "newest");
    Test.assertEqual(PodcastSettings.list().size(), 0);
    Test.assert(PodcastSettings.save(show, "A show", true, 0, "invalid", false));
    Test.assertEqual(PodcastSettings.get(show)["limit"], 1);
    Test.assertEqual(PodcastSettings.get(show)["order"], "newest");
    Test.assert(PodcastSettings.save(show, "A show", true, 99, "oldest", true));
    var config = PodcastSettings.get(show);
    Test.assertEqual(config["limit"], 5);
    Test.assertEqual(config["order"], "oldest");
    Test.assert(config["removeFinished"]);
    state.restore();
    logger.debug("new shows off; unfinished count clamps 1..5; defaults safe");
    return true;
}

(:test)
function podcastSettingsCapAndGenerations(logger) {
    var state = new PodcastSettingsTestState();
    for (var i = 0; i < 10; ++i) {
        Test.assert(PodcastSettings.save("__pod_show_" + i.toString(), "Show", true, 1, "newest", false));
    }
    Test.assert(!PodcastSettings.save("__pod_show_10", "Extra", true, 1, "newest", false));
    var old = PodcastSettings.get("__pod_show_0")["generation"];
    Test.assert(PodcastSettings.matches("__pod_show_0", old));
    PodcastSettings.save("__pod_show_0", "Show", true, 3, "oldest", false);
    Test.assert(!PodcastSettings.matches("__pod_show_0", old));
    var edited = PodcastSettings.get("__pod_show_0")["generation"];
    PodcastSettings.save("__pod_show_0", "Show", false, 3, "oldest", false);
    Test.assert(!PodcastSettings.matches("__pod_show_0", edited));
    Test.assert(PodcastSettings.save("__pod_show_10", "Extra", true, 1, "newest", false));
    Test.assertEqual(PodcastSettings.list().size(), 10);
    state.restore();
    logger.debug("cap is ten enabled shows; settings edits and disable invalidate snapshots");
    return true;
}

(:test)
function podcastOwnershipNeverClaimsManualAndAdoptionCancelsOldBytes(logger) {
    var state = new PodcastSettingsTestState();
    var show = "__pod_show_0";
    var automatic = "__pod_episode_0";
    var manual = "__pod_episode_1";
    PodcastSettings.save(show, "Show", true, 1, "newest", false);
    var generation = PodcastSettings.get(show)["generation"];
    JobStore.put(manual, { "gen" => 3 });
    Test.assert(PodcastSettings.owner(manual) == null);
    Test.assert(!PodcastSettings.claim(manual, show, generation));
    Test.assert(PodcastSettings.claim(automatic, show, generation));
    var originalJobGeneration = JobStore.nextGeneration();
    JobStore.put(automatic, { "gen" => originalJobGeneration, "autoShow" => show,
        "autoGeneration" => generation, "retryAt" => 100 });
    var before = PodcastSettings.epoch();
    PodcastSettings.adopt(automatic);
    Test.assert(PodcastSettings.epoch() > before);
    Test.assert(PodcastSettings.owner(automatic) == null);
    var job = JobStore.get(automatic);
    Test.assert(job["gen"] > originalJobGeneration);
    Test.assertEqual(job["gen"], Application.Storage.getValue("jobGeneration"));
    Test.assert(job["autoShow"] == null);
    Test.assert(job["autoGeneration"] == null);
    Test.assert(job["retryAt"] == null);
    Test.assertEqual(JobStore.get(manual)["gen"], 3);
    state.restore();
    logger.debug("legacy jobs remain manual; Keep on watch adopts safely and rejects stale automatic bytes");
    return true;
}

(:test)
function podcastDisableCancelsOnlyAutomaticAndKeepsMetadata(logger) {
    var state = new PodcastSettingsTestState();
    var show = "__pod_show_0";
    var automatic = "__pod_episode_0";
    var manual = "__pod_episode_1";
    PodcastSettings.save(show, "Show", true, 1, "newest", false);
    var generation = PodcastSettings.get(show)["generation"];
    Test.assert(PodcastSettings.claim(automatic, show, generation));
    BookStore.ensureMeta(automatic, "Episode", "Show", [120], 0, 100);
    BookStore.saveChunk(automatic, 0, "__pod_settings_fake_ref__");
    BookStore.addToIndex(automatic);
    Test.assert(PodcastSettings.claim("__pod_episode_2", show, generation));
    JobStore.put("__pod_episode_2", { "gen" => 3, "autoShow" => show });
    JobStore.put(automatic, { "gen" => 1, "autoShow" => show });
    JobStore.put(manual, { "gen" => 2 });
    PodcastSettings.save(show, "Show", false, 1, "newest", false);
    Test.assert(JobStore.get(automatic) == null);
    Test.assert(PodcastSettings.owner("__pod_episode_2") == null);
    Test.assert(JobStore.get(manual) != null);
    Test.assert(BookStore.get(automatic) != null);
    Test.assert(PodcastSettings.owner(automatic) != null);
    Test.assert(!PodcastSettings.claim("__pod_episode_2", show, generation));
    PodcastSettings.save(show, "Show", true, 2, "oldest", true);
    Test.assert(PodcastSettings.owner(automatic) != null);
    Test.assertEqual(PodcastSettings.owned(show).size(), 1);
    state.restore();
    logger.debug("disable removes only owned jobs, preserves downloaded state and ownership across re-enable");
    return true;
}

(:test)
function podcastSuppressionIsBoundedAndManualChoiceRetries(logger) {
    var state = new PodcastSettingsTestState();
    var show = "__pod_show_0";
    var itemId = "__pod_episode_0";
    PodcastSettings.save(show, "Show", true, 1, "newest", false);
    var generation = PodcastSettings.get(show)["generation"];
    Test.assert(PodcastSettings.claim(itemId, show, generation));
    PodcastSettings.suppress(itemId);
    Test.assert(PodcastSettings.isSuppressed(itemId));
    PodcastSettings.adopt(itemId);
    Test.assert(!PodcastSettings.isSuppressed(itemId));
    for (var i = 0; i <= PodcastSettings.MAX_SUPPRESSED; ++i) {
        var episode = "__pod_episode_" + i.toString();
        Test.assert(PodcastSettings.claim(episode, show, generation));
        PodcastSettings.suppress(episode);
    }
    var config = PodcastSettings.get(show);
    Test.assert(!config["enabled"]);
    Test.assertEqual(config["suppressed"].size(), PodcastSettings.MAX_SUPPRESSED);
    PodcastSettings.save(show, "Show", true, 1, "newest", false);
    Test.assertEqual(PodcastSettings.get(show)["suppressed"].size(), 0);
    state.restore();
    logger.debug("clear/delete exclusions persist; limit pauses show; explicit enable or download retries");
    return true;
}

(:test)
function podcastCredentialChangeCancelsBeforeReleasingOwnership(logger) {
    var state = new PodcastSettingsTestState();
    var show = "__pod_show_0";
    var automatic = "__pod_episode_0";
    var manual = "__pod_episode_1";
    PodcastSettings.save(show, "Show", true, 1, "newest", false);
    var generation = PodcastSettings.get(show)["generation"];
    Test.assert(PodcastSettings.claim(automatic, show, generation));
    JobStore.put(automatic, { "gen" => 1, "autoShow" => show });
    JobStore.put(manual, { "gen" => 2 });
    Application.Storage.setValue(Store.TOKEN, "another-account");
    Test.assertEqual(PodcastSettings.list().size(), 0);
    Test.assert(JobStore.get(automatic) == null);
    Test.assert(JobStore.get(manual) != null);
    Test.assert(PodcastSettings.owner(automatic) == null);
    Test.assert(!PodcastSettings.matches(show, generation));
    var epoch = PodcastSettings.epoch();
    PodcastSettings.list();
    PodcastSettings.owner(automatic);
    Test.assertEqual(PodcastSettings.epoch(), epoch);
    PodcastSettings.save(show, "New account show", true, 1, "newest", false);
    Test.assert(!PodcastSettings.matches(show, generation));
    state.restore();
    logger.debug("account change cannot reuse old automatic authority; unchanged reads do not churn epochs");
    return true;
}

(:test)
function podcastSpeedSelectionPersistsAndInvalidatesDiscovery(logger) {
    var state = new PodcastSettingsTestState();
    var show = "__pod_show_0";
    Test.assertEqual(PodcastSettings.get(show)["speed"], 100);
    PodcastSettings.save(show, "Show", true, 2, "newest", false);
    var generation = PodcastSettings.get(show)["generation"];
    PodcastSettings.setSpeed(show, "Show", 150);
    Test.assertEqual(PodcastSettings.get(show)["speed"], 150);
    Test.assert(!PodcastSettings.matches(show, generation));
    PodcastSettings.save(show, "Show", true, 4, "oldest", true);
    Test.assertEqual(PodcastSettings.get(show)["speed"], 150);
    PodcastSettings.setSpeed(show, "Show", 999);
    Test.assertEqual(PodcastSettings.get(show)["speed"], 100);
    state.restore();
    logger.debug("show speed uses existing choices; other edits preserve it; changes invalidate pending discovery");
    return true;
}

(:test)
function podcastAdoptionGenerationSurvivesClearAndRequeue(logger) {
    var state = new PodcastSettingsTestState();
    var show = "__pod_show_0";
    var episode = "__pod_episode_0";
    var files = { "title" => "Episode", "author" => "Show",
        "files" => [{ "ino" => "123", "duration" => 600 }], "progress" => null };
    PodcastSettings.save(show, "Show", true, 1, "newest", false);
    Test.assert(PodcastSettings.claim(episode, show, PodcastSettings.get(show)["generation"]));
    Test.assert(Downloads.queue(episode, 100, files, true) == null);
    var automaticGeneration = JobStore.get(episode)["gen"];
    PodcastSettings.adopt(episode);
    var inFlightGeneration = JobStore.get(episode)["gen"];
    var inFlightChunk = JobStore.get(episode)["done"];
    Test.assert(inFlightGeneration > automaticGeneration);
    Test.assertEqual(Application.Storage.getValue("jobGeneration"), inFlightGeneration);
    JobStore.clearAll();
    Test.assert(JobStore.get(episode) == null);
    Test.assert(Downloads.queue(episode, 200, files, false) == null);
    var replacement = JobStore.get(episode);
    Test.assert(replacement["gen"] > inFlightGeneration);
    Test.assertEqual(replacement["gen"], Application.Storage.getValue("jobGeneration"));
    Test.assertEqual(replacement["done"], inFlightChunk);
    Test.assertEqual(replacement["speed"], 200);
    // Same episode and chunk are deliberately reused; only the persistent
    // generation distinguishes the stale 1x callback from the new 2x job.
    Test.assert(replacement["gen"] != inFlightGeneration);
    state.restore();
    logger.debug("Keep on watch reserves a persistent generation; clearing/requeueing cannot accept its stale bytes");
    return true;
}
