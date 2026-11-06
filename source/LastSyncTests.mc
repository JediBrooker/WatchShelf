using Toybox.Graphics;
using Toybox.Lang;
using Toybox.Math;
using Toybox.System;
using Toybox.Test;
using Toybox.WatchUi;

// The "Last sync" diagnostic (issue #44 made it necessary: "stopped at 18%, then
// sat at 0% for 15 minutes" could not be diagnosed from a watch). The real
// callback chains and Storage run below; transport, the clock and the Storage
// write itself are the only things replaced.
(:test)
class LastSyncHarness extends PodcastDelegateHarness {
    var clock = 100000;
    var writes = 0;
    var failWrites = false;
    function initialize() { PodcastDelegateHarness.initialize(); }
    function clockSec() { return clock; }
    function writeLastSync(record) {
        writes += 1;
        if (failWrites) { throw new Lang.Exception(); }
        PodcastDelegateHarness.writeLastSync(record);
    }
}

(:test)
module LastSyncFixtures {
    // 300s => three chunks: 0-15, 15-195, 195-300.
    function queueShort() { SyncResumeFixtures.queueManual(); }
    // 3600s => enough chunks that a test can land many in one run.
    function queueLong() {
        PodcastFixtures.clear();
        var files = { "title" => "Long", "author" => "Show",
            "files" => [{ "ino" => "1", "duration" => 3600 }], "progress" => null };
        Test.assertMessage(Downloads.queue(PodcastFixtures.MANUAL, 100, files, false) == null, "long queued");
    }
    function saved() { return LastSync.get(); }
    function contains(text, part) {
        Test.assertMessage(text.find(part) != null, "expected '" + part + "' in: " + text);
    }
    function lacks(text, part) {
        Test.assertMessage(text.find(part) == null, "unexpected '" + part + "' in: " + text);
    }
}

// The whole point: a run that never ended reads differently from one that did,
// even though nothing got a chance to write after the process died.
(:test)
function lastSyncRunThatNeverRepliesReadsAsUnfinished(logger) {
    LastSyncFixtures.queueShort();
    var delegate = new LastSyncHarness();
    delegate.onStartSync();
    delegate = null; // hung or killed: no callback, no onStopSync, no completion

    var text = LastSync.text(LastSyncFixtures.saved());
    LastSyncFixtures.contains(text, "Did not finish");
    LastSyncFixtures.contains(text, "Parts: 0");
    LastSyncFixtures.contains(text, "No reply");
    PodcastFixtures.clear();
    return true;
}

(:test)
function lastSyncRunThatDiesMidwayKeepsWhatItDid(logger) {
    LastSyncFixtures.queueShort();
    var delegate = new LastSyncHarness();
    delegate.onStartSync();
    delegate.clock += 7;
    delegate.callback.invoke(200, new PodcastFakeAudio());
    delegate = null;

    var saved = LastSyncFixtures.saved();
    Test.assertEqual(saved["c"], 1);
    Test.assertEqual(saved["l"], 100007);
    Test.assertMessage(saved["e"] == null, "still no end time");
    var text = LastSync.text(saved);
    LastSyncFixtures.contains(text, "Did not finish");
    LastSyncFixtures.contains(text, "Parts: 1");
    LastSyncFixtures.lacks(text, "No reply");
    PodcastFixtures.clear();
    return true;
}

(:test)
function lastSyncFinishedRunRecordsEndAndCounts(logger) {
    LastSyncFixtures.queueShort();
    var delegate = new LastSyncHarness();
    delegate.onStartSync();
    for (var i = 0; i < 3; ++i) {
        delegate.clock += 10;
        delegate.callback.invoke(200, new PodcastFakeAudio());
    }
    delegate.clock += 10;
    delegate.progressWorker.respond(200, {});
    Test.assertEqual(delegate.completed, 1);

    var saved = LastSyncFixtures.saved();
    Test.assertEqual(saved["s"], 100000);
    Test.assertEqual(saved["e"], 100040);
    Test.assertEqual(saved["c"], 3);
    Test.assertEqual(saved["r"], 0);
    Test.assertEqual(saved["l"], 100030);
    Test.assertMessage(saved["f"] == null, "a clean run has no failure code");
    Test.assertMessage(saved["x"] == null, "a finished run was not stopped");
    var text = LastSync.text(saved);
    LastSyncFixtures.contains(text, "Ended");
    LastSyncFixtures.lacks(text, "Did not finish");
    PodcastFixtures.clear();
    return true;
}

// Nothing to download (a "Sync now" for progress only) still ends and says so.
(:test)
function lastSyncRunWithNoWorkStillRecordsItsEnd(logger) {
    PodcastFixtures.clear();
    var delegate = new LastSyncHarness();
    delegate.onStartSync();
    Test.assertEqual(delegate.completed, 1);
    var saved = LastSyncFixtures.saved();
    Test.assertEqual(saved["c"], 0);
    Test.assertEqual(saved["e"], 100000);
    PodcastFixtures.clear();
    return true;
}

(:test)
function lastSyncRecoveredBlipKeepsItsRetriesAndCode(logger) {
    LastSyncFixtures.queueShort();
    var delegate = new LastSyncHarness();
    delegate.onStartSync();
    delegate.callback.invoke(524, null);
    delegate.callback.invoke(-1004, null);
    delegate.callback.invoke(200, new PodcastFakeAudio());
    delegate.onStopSync();
    var saved = LastSyncFixtures.saved();
    Test.assertEqual(saved["r"], 2);
    Test.assertEqual(saved["f"], -1004);
    Test.assertEqual(saved["c"], 1);
    PodcastFixtures.clear();
    return true;
}

// The failure code is the most useful field, so a give-up is on disk at once:
// the sync may still hang in whatever it does next.
(:test)
function lastSyncGiveUpIsSavedBeforeTheRunEnds(logger) {
    LastSyncFixtures.queueShort();
    var delegate = new LastSyncHarness();
    delegate.onStartSync();
    // A landed chunk gives the progress step work, so the run stays open.
    delegate.callback.invoke(200, new PodcastFakeAudio());
    SyncResumeFixtures.failChunk(delegate, -1004);
    var saved = LastSyncFixtures.saved();
    Test.assertEqual(saved["f"], -1004);
    Test.assertEqual(saved["r"], WatchShelfSyncDelegate.CHUNK_RETRIES);
    Test.assertMessage(saved["e"] == null, "not ended yet");
    LastSyncFixtures.contains(LastSync.text(saved), "Code: -1004");
    PodcastFixtures.clear();
    return true;
}

// A stop is neither a finish nor a failure. Its -1003 is the cancellation we
// asked for, so it must not read as a failed chunk or use up a retry.
(:test)
function lastSyncStopReadsAsStoppedNotFailed(logger) {
    LastSyncFixtures.queueShort();
    var delegate = new LastSyncHarness();
    delegate.cancelReports = true;
    delegate.onStartSync();
    delegate.clock += 5;
    delegate.onStopSync();
    var saved = LastSyncFixtures.saved();
    Test.assertEqual(saved["e"], 100005);
    Test.assertEqual(saved["r"], 0);
    Test.assertMessage(saved["f"] == null, "our own cancellation is not a failure");
    var text = LastSync.text(saved);
    LastSyncFixtures.contains(text, "Stopped");
    LastSyncFixtures.lacks(text, "Ended");
    LastSyncFixtures.lacks(text, "Did not finish");
    PodcastFixtures.clear();
    return true;
}

// Bounded writes: start + first reply + one per checkpoint + end, however many
// chunks or retries land, and the value does not grow with them.
(:test)
function lastSyncWritesAreCoarseAndTheValueStaysSmall(logger) {
    LastSyncFixtures.queueLong();
    var delegate = new LastSyncHarness();
    delegate.onStartSync();
    Test.assertEqual(delegate.writes, 1);
    delegate.callback.invoke(524, null);
    Test.assertEqual(delegate.writes, 2);
    for (var i = 0; i < 8; ++i) {
        delegate.callback.invoke(524, null);
        delegate.callback.invoke(200, new PodcastFakeAudio());
    }
    Test.assertEqual(delegate.writes, 2);
    Test.assertEqual(LastSyncFixtures.saved()["c"], 0);

    delegate.clock += WatchShelfSyncDelegate.LAST_SYNC_CHECKPOINT;
    delegate.callback.invoke(200, new PodcastFakeAudio());
    Test.assertEqual(delegate.writes, 3);
    var saved = LastSyncFixtures.saved();
    Test.assertEqual(saved["c"], 9);
    Test.assertEqual(saved["r"], 9);
    Test.assertMessage(saved.size() <= 6, "fixed set of small fields");

    delegate.onStopSync();
    Test.assertEqual(delegate.writes, 4);
    Test.assertMessage(LastSyncFixtures.saved().size() <= 7, "fixed set of small fields");
    PodcastFixtures.clear();
    return true;
}

// Corrected clock: a checkpoint must not wait out a future deadline.
(:test)
function lastSyncCheckpointSurvivesTheClockGoingBack(logger) {
    LastSyncFixtures.queueLong();
    var delegate = new LastSyncHarness();
    delegate.onStartSync();
    delegate.callback.invoke(200, new PodcastFakeAudio());
    Test.assertEqual(delegate.writes, 2);
    delegate.clock -= 86400;
    delegate.callback.invoke(200, new PodcastFakeAudio());
    Test.assertEqual(delegate.writes, 3);
    delegate.onStopSync();
    PodcastFixtures.clear();
    return true;
}

(:test)
function lastSyncFailedWriteNeverBreaksTheSync(logger) {
    LastSyncFixtures.queueShort();
    var delegate = new LastSyncHarness();
    delegate.failWrites = true;
    delegate.onStartSync();                                    // start marker
    delegate.callback.invoke(200, new PodcastFakeAudio());     // first reply
    Test.assertEqual(SyncResumeFixtures.job()["done"], 1);
    Test.assertEqual(delegate.audio, 2);
    SyncResumeFixtures.failChunk(delegate, -1004);             // forced give-up
    Test.assertEqual(SyncResumeFixtures.job()["done"], 1);
    Test.assertMessage(SyncResumeFixtures.job()["retryAt"] != null, "still paused for resume");
    delegate.progressWorker.respond(200, {});                  // end
    Test.assertEqual(delegate.completed, 1);
    Test.assertMessage(LastSyncFixtures.saved() == null, "writes really did fail");
    PodcastFixtures.clear();
    return true;
}

(:test)
function lastSyncLateCallbackCannotRewriteAFinishedRun(logger) {
    LastSyncFixtures.queueShort();
    var delegate = new LastSyncHarness();
    delegate.onStartSync();
    var late = delegate.callback;
    delegate.clock += 5;
    delegate.onStopSync();
    var writes = delegate.writes;
    delegate.clock += 3600;
    late.invoke(200, new PodcastFakeAudio());
    Test.assertEqual(delegate.discarded, 1);
    Test.assertEqual(delegate.writes, writes);
    var saved = LastSyncFixtures.saved();
    Test.assertEqual(saved["c"], 0);
    Test.assertEqual(saved["e"], 100005);
    PodcastFixtures.clear();
    return true;
}

(:test)
function lastSyncEachRunReplacesThePrevious(logger) {
    LastSyncFixtures.queueLong();
    var delegate = new LastSyncHarness();
    delegate.onStartSync();
    delegate.callback.invoke(524, null);
    delegate.callback.invoke(200, new PodcastFakeAudio());
    delegate.onStopSync();

    delegate = new LastSyncHarness();
    delegate.clock = 200000;
    delegate.onStartSync();
    var saved = LastSyncFixtures.saved();
    Test.assertEqual(saved["s"], 200000);
    Test.assertEqual(saved["c"], 0);
    Test.assertEqual(saved["r"], 0);
    Test.assertMessage((saved["f"] == null) && (saved["e"] == null) && (saved["l"] == null)
        && (saved["x"] == null), "a new run starts clean");
    delegate.onStopSync();
    PodcastFixtures.clear();
    return true;
}

// ErrorView centres one block of FONT_SMALL with no wrapping, so a line wider
// than the round screen at its height is silently clipped. Measured with the
// device's real font on every test device, not guessed from a character count.
(:test)
function lastSyncWorstCaseTextFitsARoundScreen(logger) {
    var settings = System.getDeviceSettings();
    if (settings.screenShape != System.SCREEN_SHAPE_ROUND) { return true; }
    var bitmap = (Graphics has :createBufferedBitmap)
        ? Graphics.createBufferedBitmap({ :width => 1, :height => 1 }).get()
        : new Graphics.BufferedBitmap({ :width => 1, :height => 1 });
    var dc = bitmap.getDc();
    var lineHeight = dc.getFontHeight(Graphics.FONT_SMALL);
    var radius = settings.screenWidth / 2.0;

    var worst = Chunks.MAX_TOTAL;
    // A two-digit date in a month with a wide name.
    var at = 1790772000;
    var records = [
        { "s" => at, "c" => worst, "r" => worst * 2, "f" => -1004, "l" => at },
        { "s" => at, "e" => at, "c" => worst, "r" => worst * 2, "f" => -1004, "l" => at },
        { "s" => at, "e" => at, "x" => 1, "c" => worst, "r" => worst * 2, "f" => -1004, "l" => at },
        { "s" => at, "c" => 0, "r" => 0 }
    ];
    for (var r = 0; r < records.size(); ++r) {
        var lines = LastSyncFixtureLines.split(LastSync.text(records[r]));
        var top = -lines.size() * lineHeight / 2.0;
        for (var i = 0; i < lines.size(); ++i) {
            var nearEdge = top + (i * lineHeight);
            var farEdge = nearEdge + lineHeight;
            var y = (nearEdge.abs() > farEdge.abs()) ? nearEdge.abs() : farEdge.abs();
            Test.assertMessage(y < radius, lines.size() + " lines are too tall");
            var chord = 2 * Math.sqrt((radius * radius) - (y * y));
            var width = dc.getTextWidthInPixels(lines[i], Graphics.FONT_SMALL);
            Test.assertMessage(width <= chord, "'" + lines[i] + "' is " + width + "px wide, screen is "
                + chord.toNumber() + "px at that height");
        }
    }
    return true;
}

(:test)
module LastSyncFixtureLines {
    function split(text) {
        var lines = [];
        var at = text.find("\n");
        while (at != null) {
            lines.add(text.substring(0, at));
            text = text.substring(at + 1, text.length());
            at = text.find("\n");
        }
        lines.add(text);
        return lines;
    }
}

// A smoke test of the tap: fr645m has no WatchUi.getCurrentView to assert with.
(:test)
function lastSyncMenuRowTapRunsWithAndWithoutARecord(logger) {
    PodcastFixtures.clear();
    var row = new WatchUi.MenuItem("Last sync", null, "lastsync", null);
    new DownloadedMenuDelegate().onSelect(row);
    var delegate = new LastSyncHarness();
    delegate.onStartSync();
    new DownloadedMenuDelegate().onSelect(row);
    WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
    PodcastFixtures.clear();
    return true;
}

(:test)
function lastSyncMenuRowOnlyAppearsOnceARunHasBeenRecorded(logger) {
    PodcastFixtures.clear();
    Test.assertEqual(new DownloadedMenu().findItemById("lastsync"), -1);
    var delegate = new LastSyncHarness();
    delegate.onStartSync();
    Test.assertMessage(new DownloadedMenu().findItemById("lastsync") >= 0, "row offered after a run");
    PodcastFixtures.clear();
    return true;
}
