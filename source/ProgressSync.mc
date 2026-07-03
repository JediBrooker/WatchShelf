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
// stacks requests into the 512KB sync heap. When the chain finishes (or on any
// error) it invokes the continuation exactly once, so downloads/deletes always
// run even if a progress request failed. Nothing here is load-bearing for the
// download path; it only front-runs it.
class ProgressSync {

    private var mPulls;    // [ itemId, ... ] downloaded books to pull
    private var mPushes;   // [ itemId, ... ] still-dirty books to push (built
                           // AFTER the pulls, so the merge has already run)
    private var mPhase;    // 0 = pulling, 1 = pushing
    private var mIdx;
    private var mCurId;
    private var mCurTs;
    private var mCb;

    function initialize() {
        mPulls = [];
        mPushes = [];
        mPhase = 0;
        mIdx = 0;
    }

    function start(cb) {
        mCb = cb;
        try {
            var index = Application.Storage.getValue(Store.BOOK_INDEX);
            if (index == null) { index = []; }
            mPulls = index;
        } catch (e) {
            System.println("ProgressSync build failed: " + e.getErrorMessage());
            mPulls = [];
        }
        step();
    }

    function step() {
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
                AbsApi.getProgress(mCurId, method(:onPullDone));
                return;
            }

            // Push phase.
            if (mIdx >= mPushes.size()) { finish(); return; }
            mCurId = mPushes[mIdx];
            mIdx += 1;
            var e = Progress.get(mCurId);
            if (e == null) { step(); return; }
            mCurTs = e[1];
            // duration unknown here -> null keeps ABS's stored duration.
            AbsApi.postProgress(mCurId, e[0], null, e[1], method(:onPushDone));
        } catch (ex) {
            System.println("ProgressSync step failed: " + ex.getErrorMessage());
            // Never let a progress hiccup strand the sync - advance regardless.
            if (mPhase == 0 && mIdx >= mPulls.size()) { mPushes = []; }
            step();
        }
    }

    function onPullDone(code, data) {
        try {
            if (code == 200) {
                var pr = AbsApi.readProgress(data); // [posSec, tsSec] or null
                if (pr != null) { Progress.mergeServer(mCurId, pr[0], pr[1]); }
            }
        } catch (ex) {
            System.println("ProgressSync pull failed: " + ex.getErrorMessage());
        }
        step();
    }

    function onPushDone(code, data) {
        if (code == 200) { Progress.markClean(mCurId, mCurTs); }
        else { System.println("ProgressSync push failed: " + code); }
        step();
    }

    function finish() {
        if (mCb != null) {
            var cb = mCb;
            mCb = null;
            cb.invoke();
        }
    }
}
