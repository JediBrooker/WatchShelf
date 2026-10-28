using Toybox.Application;
using Toybox.System;

// The two-way progress exchange, run as one bounded, SEQUENTIAL chain inside a
// sync (SyncDelegate.onStartSync). Order matters:
//
//   1. PULL every downloaded book's position from ABS and last-write-wins merge
//      it locally. This picks up a position set on another device AND resolves
//      conflicts BEFORE we push - ABS's PATCH is a blind write, so pushing a
//      stale offline listen first could clobber a newer position from the phone.
//   2. PUSH whatever is still dirty after the merge (i.e. a genuinely newer
//      local listen), stamped with the watch's own listen time so other devices
//      order it correctly.
//
// One request at a time - same discipline as the download engine - so it never
// stacks requests into the 512KB sync heap. It runs as the FINAL step of a sync
// (SyncDelegate.finishSync), AFTER downloads/deletes are done, and invokes its
// continuation exactly once when the chain ends - even on a request error - so
// the sync always reaches notifySyncComplete. Nothing here is load-bearing for
// the download path: by the time it runs, downloads have already finished.
class ProgressSync {

    private var mPulls;    // [ itemId, ... ] downloaded books to pull
    private var mPushes;   // [ itemId, ... ] still-dirty books to push (built
                           // AFTER the pulls, so the merge has already run)
    private var mPhase;    // 0 = pulling, 1 = pushing
    private var mIdx;
    private var mCurId;
    private var mCurTs;
    private var mCurPos;
    private var mCurFinished;
    private var mCb;
    private var mStopped;
    private var mPullOk;
    private var mRetentionCount;
    private var mBlocked;
    private var mAcks;
    private var mSerial;
    private var mWaiting;

    function initialize() {
        mPulls = [];
        mPushes = [];
        mPhase = 0;
        mIdx = 0;
        mStopped = false;
        mPullOk = {}; mRetentionCount = 0;
        mBlocked = {};
        mAcks = {};
        mSerial = 0;
        mWaiting = false;
    }

    function cancel() { mStopped = true; mCb = null; mWaiting = false; }
    function acknowledgements() { return mAcks; }

    function requestContext() {
        mSerial += 1;
        mWaiting = true;
        return { "serial" => mSerial };
    }
    function accept(context) {
        if (mStopped || !mWaiting || context["serial"] != mSerial) { return false; }
        mWaiting = false;
        return true;
    }

    function start(cb) {
        mCb = cb;
        try {
            var index = Application.Storage.getValue(Store.BOOK_INDEX);
            if (index == null) { index = []; }
            mPulls = index;
            var pending = PodcastRetention.pending();
            if (pending != null) {
                // Recovery must receive one of the 50 bounded retention ack
                // slots; placing it last could deadlock behind its own journal.
                mPulls = [pending["item"]];
                for (var i = 0; i < index.size(); ++i) {
                    if (!index[i].equals(pending["item"])) { mPulls.add(index[i]); }
                }
            }
        } catch (e) {
            System.println("ProgressSync build failed: " + e.getErrorMessage());
            mPulls = [];
        }
        step();
    }

    function step() {
        if (mStopped) { return; }
        try {
            if (mPhase == 0) {
                if (mIdx >= mPulls.size()) {
                    // Pulls done: NOW compute what remains dirty and push it.
                    mPushes = Progress.dirtyIds();
                    mPhase = 1;
                    mIdx = 0;
                    step();
                    return;
                }
                mCurId = mPulls[mIdx];
                mIdx += 1;
                var listener = new RequestDelegate(method(:onPullDone), requestContext());
                requestPull(mCurId, listener.method(:onWebResponse));
                return;
            }

            // Push phase.
            if (mIdx >= mPushes.size()) { finish(); return; }
            mCurId = mPushes[mIdx];
            mIdx += 1;
            var e = Progress.get(mCurId);
            if (e == null) { step(); return; }
            mCurTs = e[1];
            mCurPos = e[0];
            mCurFinished = Progress.entryFinished(e);
            // Always carry duration when known so a first offline write has
            // complete progress metadata. Ordinary positions omit isFinished;
            // moving below ABS's completion threshold reopens a reread.
            var duration = bookDuration(mCurId);
            var finishValue = mCurFinished ? true : null;
            var listener = new RequestDelegate(method(:onPushDone), requestContext());
            requestPush(mCurId, e[0], duration, e[1],
                finishValue, listener.method(:onWebResponse));
        } catch (ex) {
            System.println("ProgressSync step failed: " + ex.getErrorMessage());
            // Never let a progress hiccup strand the sync - advance regardless.
            if (mPhase == 0 && mIdx >= mPulls.size()) { mPushes = []; }
            step();
        }
    }

    function trackRetention(itemId, remoteFinished) {
        if (!Progress.isFinished(itemId) && !remoteFinished) { return false; }
        if (mPullOk.hasKey(itemId)) { return true; }
        if (mRetentionCount >= 50) { return false; }
        var owner = PodcastSettings.owner(itemId);
        if (owner == null) { return false; }
        var settings = PodcastSettings.get(owner["show"]);
        if (!settings["enabled"] || !settings["removeFinished"]) { return false; }
        mPullOk[itemId] = false; mRetentionCount += 1;
        return true;
    }

    function requestPull(itemId, cb) { AbsApi.getProgress(itemId, cb); }
    function requestPush(itemId, pos, duration, ts, finished, cb) {
        AbsApi.postProgress(itemId, pos, duration, ts, finished, cb);
    }

    function onPullDone(code, data, context) {
        if (!accept(context)) { return; }
        try {
            var retain = trackRetention(mCurId, Downloads.validProgress(data) && data["isFinished"]);
            if ((code == 200) && Downloads.validProgress(data)) {
                var pr = AbsApi.readProgress(data);
                var before = Progress.get(mCurId);
                // A dirty local listen displaced by the conflict policy may be
                // valuable even if the winner is finished. Never prune it in
                // this exchange; the user must get a later successful check.
                if (retain && (before != null) && before[2] && (pr[1] > before[1])) {
                    mBlocked[mCurId] = true;
                }
                if (retain) { mPullOk[mCurId] = true; }
                Progress.mergeServer(mCurId, pr[0], pr[1], pr[2]);
                var now = Progress.get(mCurId);
                if (retain && (now != null) && !now[2] && (now[0] == pr[0])
                    && (Progress.entryFinished(now) == pr[2]) && (mBlocked[mCurId] != true)) {
                    mAcks[mCurId] = [now[0], now[1], Progress.entryFinished(now)];
                }
            }
            // An empty, valid server response authorizes a later push but is
            // never itself evidence that finished local progress was received.
            else if ((code == 200) && (data instanceof Toybox.Lang.Dictionary)
                && (data.size() == 0) && retain) { mPullOk[mCurId] = true; }
        } catch (ex) {
            if (mPullOk.hasKey(mCurId)) { mPullOk[mCurId] = false; }
            System.println("ProgressSync pull failed: " + ex.getErrorMessage());
        }
        step();
    }

    function bookDuration(itemId) {
        var meta = BookStore.get(itemId);
        if ((meta == null) || (meta["durs"] == null)) { return null; }
        var total = 0;
        var durs = meta["durs"];
        for (var i = 0; i < durs.size(); ++i) { total += durs[i]; }
        return (total > 0) ? total : null;
    }

    function onPushDone(code, data, context) {
        if (!accept(context)) { return; }
        if (code == 200) {
            Progress.markClean(mCurId, mCurTs, mCurPos, mCurFinished);
            var now = Progress.get(mCurId);
            if ((mPullOk[mCurId] == true) && (mBlocked[mCurId] != true)
                && (now != null) && !now[2] && now[0] == mCurPos && now[1] == mCurTs
                && Progress.entryFinished(now) == mCurFinished) {
                mAcks[mCurId] = [now[0], now[1], mCurFinished];
            }
        } else { System.println("ProgressSync push failed: " + code); }
        step();
    }

    function finish() {
        if (mStopped) { return; }
        mStopped = true;
        if (mCb != null) {
            var cb = mCb;
            mCb = null;
            cb.invoke();
        }
    }
}
