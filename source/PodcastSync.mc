using Toybox.Application;
using Toybox.Lang;
using Toybox.System;

// Persist the retry deadline BEFORE dispatch. Empty success is fresh; a crash,
// cancel, unavailable Wi-Fi or old sidecar remains a one-hour retry. The cursor
// advances per attempted show, so repeated interrupted syncs do not starve the
// end of the bounded subscription list.
module PodcastSchedule {
    const KEY = "podcastSchedule";
    const SUCCESS = 21600;
    const RETRY = 3600;
    function state() {
        var s = Application.Storage.getValue(KEY);
        return (s instanceof Lang.Dictionary) ? s : {};
    }
    function elapsed(now, deadline, maximum) {
        if (!Downloads.numeric(deadline)) { return true; }
        return (deadline <= now) || ((deadline - now) > maximum);
    }
    function due(now) { return elapsed(now, state()["next"], SUCCESS); }
    function begin(now) {
        var s = state();
        s["attempt"] = now;
        s["next"] = now + RETRY;
        Application.Storage.setValue(KEY, s);
    }
    function cursor(value) {
        var s = state(); s["cursor"] = value;
        Application.Storage.setValue(KEY, s);
    }
    function success(now) {
        var s = state(); s["success"] = now; s["next"] = now + SUCCESS;
        Application.Storage.setValue(KEY, s);
    }
    function powered() {
        // SDK 9.2 api.mir System.Stats.charging: true while on the cradle or
        // cable, including at full charge; available since Connect IQ 3.0.
        try { return System.getSystemStats().charging; } catch (e) { return false; }
    }
    function discoveryNeeded(force, charging, now) {
        return (PodcastSettings.list().size() > 0) && (force || (charging && due(now)));
    }
    function jobAllowed(itemId, job, force, charging, now) {
        if (job["autoShow"] == null) { return true; }
        var owner = PodcastSettings.owner(itemId);
        var settings = PodcastSettings.get(job["autoShow"]);
        if ((owner == null) || !owner["show"].equals(job["autoShow"])
            || (settings == null) || !settings["enabled"]
            || PodcastSettings.isSuppressed(itemId)) { return false; }
        return (force || charging) && elapsed(now, job["retryAt"], RETRY);
    }
}

// One bounded crash-recovery record, never an ever-growing progress history.
// Progress is removed only AFTER audio deletion and only for the exact clean
// write acknowledged by this run. A restart pulls this item again, even after
// it was unindexed; pending chunks are also protected from the orphan sweep.
module PodcastRetention {
    const KEY = "podcastPrune";
    function pending() { return Application.Storage.getValue(KEY); }
    function sameProgress(itemId, ack) {
        var p = Progress.get(itemId);
        return (ack != null) && (p != null) && !p[2] && Progress.entryFinished(p)
            && ack[2] && (p[0] == ack[0]) && (p[1] == ack[1]);
    }
    function eligible(itemId, showId, generation, ack) {
        var owner = PodcastSettings.owner(itemId);
        var settings = PodcastSettings.get(showId);
        return PodcastSettings.matches(showId, generation) && (settings["removeFinished"] == true)
            && (owner != null) && owner["show"].equals(showId)
            && (JobStore.get(itemId) == null) && !PodcastSettings.isSuppressed(itemId)
            && sameProgress(itemId, ack);
    }
    function prune(itemId, showId, generation, ack) {
        if (!eligible(itemId, showId, generation, ack)) { return false; }
        var p = pending();
        if ((p != null) && !p["item"].equals(itemId)) { return false; }
        Application.Storage.setValue(KEY, { "item" => itemId, "show" => showId,
            "generation" => generation, "ack" => ack });
        // No asynchronous boundary between the final recheck and deletion.
        if (!eligible(itemId, showId, generation, ack)) { return false; }
        BookStore.removeFromIndex(itemId);
        BookStore.deleteBook(itemId);
        if (sameProgress(itemId, ack)) { Progress.remove(itemId); }
        PodcastSettings.forget(itemId);
        Application.Storage.deleteValue(KEY);
        return true;
    }
    function restoreIfInvalid() {
        var p = pending();
        if (p == null) { return; }
        var owner = PodcastSettings.owner(p["item"]);
        var settings = PodcastSettings.get(p["show"]);
        var progress = Progress.get(p["item"]);
        if (((progress != null) && (progress[2] || !Progress.entryFinished(progress)
                || !sameProgress(p["item"], p["ack"])))
            || !PodcastSettings.matches(p["show"], p["generation"])
            || (settings["removeFinished"] != true) || (owner == null)
            || !owner["show"].equals(p["show"])) {
            var meta = BookStore.get(p["item"]);
            // deleteBook removes pages from the end and metadata last, so a
            // surviving prefix still has its original absolute coordinates.
            if ((meta != null) && (meta["durs"] != null) && (BookStore.count(p["item"]) > 0)) {
                BookStore.addToIndex(p["item"]);
            }
            Application.Storage.deleteValue(KEY);
        }
    }
}

class PodcastSync {
    private var mCb;
    private var mStopped;
    private var mForce;
    private var mEpoch;
    private var mShows;
    private var mIndex;
    private var mVisited;
    private var mSettings;
    private var mEpisodes;
    private var mEpisodeIndex;
    private var mAcks;
    private var mInventory;
    private var mFailed;
    private var mSerial;
    private var mWaiting;

    function initialize() {
        mStopped = false; mFailed = false; mSerial = 0; mWaiting = false;
        mVisited = 0; mEpisodes = []; mEpisodeIndex = 0;
    }
    function charging() { return PodcastSchedule.powered(); }
    function permitted() {
        return !mStopped && (mEpoch == PodcastSettings.epoch()) && (mForce || charging());
    }
    function cancel() { mStopped = true; mCb = null; mWaiting = false; }
    function start(force, acks, cb) {
        mForce = force; mAcks = acks; mCb = cb; mEpoch = PodcastSettings.epoch();
        mShows = PodcastSettings.list();
        mInventory = PodcastSettings.inventory();
        if (mShows.size() == 0 || !permitted()) { finish(false); return; }
        var cursor = PodcastSchedule.state()["cursor"];
        mIndex = (cursor instanceof Lang.Number) ? cursor : 0;
        if (mIndex < 0 || mIndex >= mShows.size()) { mIndex = 0; }
        PodcastSchedule.begin(Progress.nowSec());
        PodcastRetention.restoreIfInvalid();
        nextShow();
    }
    function context() {
        mSerial += 1; mWaiting = true;
        return { "serial" => mSerial };
    }
    function accept(ctx) {
        if (mStopped || !mWaiting || ctx["serial"] != mSerial) { return false; }
        mWaiting = false;
        if (!permitted()) { finish(false); return false; }
        return true;
    }
    function requestCandidates(settings, cb) {
        AbsApi.getPodcastCandidates(settings["id"], settings["limit"], settings["order"], cb);
    }
    function requestFiles(itemId, cb) { AbsApi.getFiles(itemId, cb); }
    function nextShow() {
        if (!permitted()) { finish(false); return; }
        if ((mVisited >= mShows.size()) || (mVisited >= 10)) { finish(!mFailed); return; }
        var show = mShows[mIndex];
        mIndex = (mIndex + 1) % mShows.size(); mVisited += 1;
        PodcastSchedule.cursor(mIndex);
        mSettings = PodcastSettings.get(show);
        if ((mSettings == null) || !mSettings["enabled"]) { finish(false); return; }
        var listener = new RequestDelegate(method(:onCandidates), context());
        try { requestCandidates(mSettings, listener.method(:onWebResponse)); }
        catch (e) { mWaiting = false; mFailed = true; nextShow(); }
    }
    function validCandidates(data, settings) {
        if (!(data instanceof Lang.Dictionary) || data["version"] != 1
            || !Downloads.numeric(data["checkedAtSec"]) || data["checkedAtSec"] < 0 || data["checkedAtSec"] > 2147483647
            || !(data["show"] instanceof Lang.Dictionary)
            || !(data["show"]["id"] instanceof Lang.String)
            || !data["show"]["id"].equals(settings["id"])
            || !(data["episodes"] instanceof Lang.Array)
            || data["episodes"].size() > settings["limit"] || data["episodes"].size() > 5) { return false; }
        var prefix = settings["id"] + "__";
        var ids = [];
        for (var i = 0; i < data["episodes"].size(); ++i) {
            var row = data["episodes"][i];
            if (!(row instanceof Lang.Dictionary) || !(row["id"] instanceof Lang.String)
                || row["id"].length() > 256 || row["id"].length() <= prefix.length()
                || !row["id"].substring(0, prefix.length()).equals(prefix)
                || !(row["title"] instanceof Lang.String) || row["title"].length() > 180
                || !(row["author"] instanceof Lang.String) || row["author"].length() > 180
                || !Downloads.numeric(row["publishedAt"]) || row["publishedAt"] < 0 || row["publishedAt"] > 2147483647
                || Downloads.containsId(ids, row["id"])) { return false; }
            if ((row["progress"] != null) && (!Downloads.validProgress(row["progress"])
                || row["progress"]["isFinished"] == true)) { return false; }
            ids.add(row["id"]);
        }
        return true;
    }
    function onCandidates(code, data, ctx) {
        if (!accept(ctx)) { return; }
        if (!PodcastSettings.matches(mSettings["id"], mSettings["generation"])) { finish(false); return; }
        if (code == 404) {
            Application.Storage.setValue("podcastStatus", "Update sidecar");
            finish(false); return;
        }
        if ((code != 200) || !validCandidates(data, mSettings)) {
            mFailed = true; nextShow(); return;
        }
        Application.Storage.deleteValue("podcastStatus");
        // Discovery success alone cannot prune: the exact per-item progress
        // acknowledgement from this run is a separate mandatory prerequisite.
        pruneFinished();
        mEpisodes = data["episodes"]; mEpisodeIndex = 0;
        nextEpisode();
    }
    function pruneFinished() {
        if (mSettings["removeFinished"] != true) { return; }
        var pending = PodcastRetention.pending();
        if ((pending != null) && pending["show"].equals(mSettings["id"])) {
            PodcastRetention.prune(pending["item"], mSettings["id"], mSettings["generation"], mAcks[pending["item"]]);
        }
        var owned = ownedIds(mSettings["id"]);
        // At most five deletions in one callback. More finished items can be
        // reclaimed on a later successful pass without monopolizing this run.
        var removed = 0;
        for (var i = 0; i < owned.size() && removed < 5; ++i) {
            if (!permitted()) { return; }
            if (PodcastRetention.prune(owned[i], mSettings["id"], mSettings["generation"], mAcks[owned[i]])) { removed += 1; }
        }
    }
    function ownedIds(showId) {
        return (mInventory[showId] == null) ? [] : mInventory[showId];
    }
    function unfinished(showId) {
        var ids = ownedIds(showId); var count = 0;
        for (var i = 0; i < ids.size(); ++i) { if (!Progress.isFinished(ids[i]) && ((JobStore.get(ids[i]) != null) || BookStore.count(ids[i]) > 0)) { count += 1; } }
        return count;
    }
    function eligible(itemId) {
        return PodcastSettings.matches(mSettings["id"], mSettings["generation"])
            && !PodcastSettings.isSuppressed(itemId) && !Progress.isFinished(itemId)
            && !Downloads.containsId(Downloads.deleteIds(), itemId)
            && (JobStore.get(itemId) == null) && (BookStore.count(itemId) == 0)
            && unfinished(mSettings["id"]) < mSettings["limit"];
    }
    function nextEpisode() {
        if (!permitted()) { finish(false); return; }
        while (mEpisodeIndex < mEpisodes.size()) {
            var row = mEpisodes[mEpisodeIndex]; mEpisodeIndex += 1;
            if (!eligible(row["id"])) { continue; }
            if (!Downloads.automaticIndexFits(row["id"])) {
                mFailed = true;
                Application.Storage.setValue("podcastStatus", "Downloads full");
                continue;
            }
            var ctx = context(); ctx["item"] = row["id"];
            var listener = new RequestDelegate(method(:onFiles), ctx);
            try { requestFiles(row["id"], listener.method(:onWebResponse)); }
            catch (e) { mWaiting = false; mFailed = true; nextEpisode(); }
            return;
        }
        nextShow();
    }
    function onFiles(code, data, ctx) {
        if (!accept(ctx)) { return; }
        if (!eligible(ctx["item"])) { nextEpisode(); return; }
        if (Progress.isFinished(ctx["item"])) { nextEpisode(); return; }
        if (code != 200) { mFailed = true; nextEpisode(); return; }
        if (!Downloads.automaticIndexFits(ctx["item"])) {
            mFailed = true;
            Application.Storage.setValue("podcastStatus", "Downloads full");
            nextEpisode(); return;
        }
        // The claim is durable BEFORE a job can become visible. Interrupted
        // writes can leave an unindexed ownership key, never a manual job.
        if (PodcastSettings.claim(ctx["item"], mSettings["id"], mSettings["generation"])) {
            var error;
            try { error = Downloads.queue(ctx["item"], PlaybackSpeed.normalize(mSettings["speed"]), data, true); }
            catch (e) { error = Rez.Strings.errNoAudio; }
            if (error == null) {
                if (mInventory[mSettings["id"]] == null) { mInventory[mSettings["id"]] = []; }
                if (!Downloads.containsId(mInventory[mSettings["id"]], ctx["item"])) {
                    mInventory[mSettings["id"]].add(ctx["item"]);
                }
            }
            if (error != null) { PodcastSettings.forget(ctx["item"]); }
            if ((error != null) && (error != Rez.Strings.nothingToDownload)
                && (error != Rez.Strings.alreadyDownloaded)) { mFailed = true; }
        }
        nextEpisode();
    }
    function finish(success) {
        if (mStopped) { return; }
        mStopped = true; mWaiting = false;
        if (success) { PodcastSchedule.success(Progress.nowSec()); }
        if (mCb != null) { var cb = mCb; mCb = null; cb.invoke(); }
    }
}
