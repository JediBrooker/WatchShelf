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

// Chunks.spans() is the single-pass companion to starts(), and playback order
// now depends on it: ContentIterator carries each chunk's span alongside its
// refId so positionAtBook() can tell which cached part contains a resume
// offset. A span that disagrees with at() would resume in the wrong part, so
// pin the agreement rather than the implementation.
(:test)
function chunksSpansMatchBoundaries(logger) {
    var durs = [195, 360];
    var spans = Chunks.spans(durs);

    // Parallel to starts()/total() - every reader indexes all three by the
    // same global chunk k.
    Test.assertEqual(spans.size(), Chunks.total(durs));
    Test.assertEqual(spans.size(), Chunks.starts(durs).size());

    // Chunk 0 is deliberately short so playback is testable almost at once;
    // every later chunk is a full LEN except a file's final remainder.
    Test.assertEqual(spans[0], 15);
    Test.assertEqual(spans[1], 180);
    Test.assertEqual(spans[2], 180);
    Test.assertEqual(spans[3], 180);

    logger.debug("spans() is parallel to starts() and honors the short first chunk");
    return true;
}

// The remainder at the end of a file is shorter than LEN, and a file shorter
// than what's left of the current chunk must not emit a negative or zero span.
(:test)
function chunksSpansTailRemainder(logger) {
    var durs = [200];
    var spans = Chunks.spans(durs);
    Test.assertEqual(spans.size(), 3);
    Test.assertEqual(spans[0], 15);
    Test.assertEqual(spans[1], 180);
    Test.assertEqual(spans[2], 5);      // 200 - 195, clamped to the file end

    // A zero-length file is skipped WITHOUT consuming the short first chunk:
    // the FIRST/LEN choice keys off chunks emitted, not the file index.
    var skipped = Chunks.spans([0, 30]);
    Test.assertEqual(skipped.size(), 2);
    Test.assertEqual(skipped[0], 15);
    Test.assertEqual(skipped[1], 15);

    logger.debug("file-final remainders clamp and empty files consume no chunk");
    return true;
}

// The property that actually matters: for EVERY chunk, the single-pass span
// equals the one at() derives. at() is O(k) per call - that quadratic cost is
// exactly why spans() exists - but a test walking a short book is cheap, and
// it's what stops the two loops from drifting apart (the module header warns
// they must stay identical).
(:test)
function chunksSpansAgreeWithAt(logger) {
    var cases = [ [195, 360], [200], [0, 30], [15], [1, 1, 1], [3600] ];
    for (var c = 0; c < cases.size(); ++c) {
        var durs = cases[c];
        var spans = Chunks.spans(durs);
        var starts = Chunks.starts(durs);
        Test.assertEqual(spans.size(), Chunks.total(durs));
        for (var k = 0; k < spans.size(); ++k) {
            var at = Chunks.at(durs, k);
            Test.assertMessage(at != null, "at() must resolve every derived chunk");
            Test.assertEqual(spans[k], at["cend"] - at["cstart"]);
            Test.assertEqual(starts[k], at["start"]);
            Test.assertMessage(spans[k] > 0, "a chunk must carry playable audio");
        }
        // Past the end both agree there is nothing there.
        Test.assertMessage(Chunks.at(durs, spans.size()) == null,
            "at() must return null past the last chunk");
    }
    logger.debug("spans()/starts() agree with at() across every chunk of each shape");
    return true;
}
