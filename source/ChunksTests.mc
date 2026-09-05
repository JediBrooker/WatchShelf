using Toybox.Test;

// Pure chunk-boundary regressions. These are compiled only for Run No Evil
// (`monkeyc -t`) and never add code or heap cost to device/store builds.
(:test)
function chunksIndexAtBoundaries(logger) {
    var durs = [195, 360];
    Test.assertEqual(Chunks.total(durs), 4);
    Test.assertEqual(Chunks.indexAt(durs, -1), 0);
    Test.assertEqual(Chunks.indexAt(durs, 0), 0);
    Test.assertEqual(Chunks.indexAt(durs, 14), 0);
    Test.assertEqual(Chunks.indexAt(durs, 15), 1);
    Test.assertEqual(Chunks.indexAt(durs, 194), 1);
    Test.assertEqual(Chunks.indexAt(durs, 195), 2);
    Test.assertEqual(Chunks.indexAt(durs, 375), 3);
    Test.assertEqual(Chunks.indexAt(durs, 555), 4);
    Test.assertEqual(Chunks.indexAt(durs, 900), 4);
    logger.debug("tail-download boundaries preserve exact chunk/file edges");
    return true;
}

(:test)
function chunksTailCoordinates(logger) {
    var durs = [195, 360];
    var c = Chunks.at(durs, Chunks.indexAt(durs, 200));
    Test.assertEqual(c["file"], 1);
    Test.assertEqual(c["cstart"], 0);
    Test.assertEqual(c["cend"], 180);
    Test.assertEqual(c["start"], 195);
    logger.debug("tail base maps back to the correct source-file range");
    return true;
}

(:test)
function playbackSpeedTimelineMapping(logger) {
    Test.assertEqual(PlaybackSpeed.normalize(null), 100);
    Test.assertEqual(PlaybackSpeed.normalize(130), 100);
    Test.assertEqual(PlaybackSpeed.normalize(125), 125);
    Test.assertEqual(PlaybackSpeed.normalize(200), 200);
    Test.assertEqual(PlaybackSpeed.sourceSeconds(60, 100), 60);
    Test.assertEqual(PlaybackSpeed.sourceSeconds(60, 125), 75);
    Test.assertEqual(PlaybackSpeed.sourceSeconds(60, 150), 90);
    Test.assertEqual(PlaybackSpeed.sourceSeconds(59, 125), 74);
    Test.assertEqual(PlaybackSpeed.sourceSeconds(60, null), 60);
    logger.debug("compressed playback maps to the source timeline");
    return true;
}

// Restarting a completed book becomes an ordinary dirty position write. The
// client deliberately omits isFinished:false: current ABS resets currentTime
// and discards the supplied position when that explicit flag is used.
(:test)
function progressRestartIsOrdinaryWrite(logger) {
    var itemId = "__watchshelf_test_restart__";
    Progress.remove(itemId);

    Progress.record(itemId, 420, 10, true);
    var e = Progress.get(itemId);
    Test.assertMessage(Progress.entryFinished(e), "fixture should start finished");

    Progress.record(itemId, 15, 11, false);
    e = Progress.get(itemId);
    Test.assertMessage(!Progress.entryFinished(e), "restart clears local finished");
    Test.assertMessage(e[2], "restart must remain dirty until its position is confirmed");

    Progress.markClean(itemId, 11, 15, false);
    e = Progress.get(itemId);
    Test.assertMessage(!e[2], "matching ordinary position response marks restart clean");

    Progress.remove(itemId);
    logger.debug("completed-book restart uses a normal position write");
    return true;
}
