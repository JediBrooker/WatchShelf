using Toybox.Application;
using Toybox.Test;

// Instrumentation for issue #61. Progress.mergeServer trusts tsSec, and local
// writes carry the WATCH's clock - so a slow watch can lose real listening to
// an older server position. Nobody has reported that; it was found by reading
// the rule. These pin what gets counted, so the decision about changing
// last-write-wins semantics can be made on evidence rather than on my reading.

// Everything stays INSIDE the (:test) functions: an unannotated global const
// or helper would be compiled into device builds too, and this file must cost
// a real build nothing.

(:test)
function conflictNotCountedForCleanEntry(logger) {
    var BOOK = "__watchshelf_conflict_test__";
    Progress.remove(BOOK); Progress.clearConflicts();
    // A CLEAN local entry being replaced is ordinary cross-device sync - the
    // watch has nothing unflushed to lose, so it must not be counted.
    Progress.record(BOOK, 100, 1000, false);
    Progress.markClean(BOOK, 1000, 100, false);
    Test.assertMessage(!Progress.get(BOOK)[2], "fixture must be clean");

    Progress.mergeServer(BOOK, 500, 2000, false);
    Test.assertEqual(Progress.get(BOOK)[0], 500);
    Test.assertMessage(Progress.conflicts() == null, "a clean overwrite is not a conflict");

    Progress.remove(BOOK); Progress.clearConflicts();
    logger.debug("replacing a flushed entry is not counted");
    return true;
}

(:test)
function conflictCountedWhenDirtyListeningIsLost(logger) {
    var BOOK = "__watchshelf_conflict_test__";
    Progress.remove(BOOK); Progress.clearConflicts();
    // Local listening at 900s, stamped ts=1000, never pushed. The server
    // claims ts=1180 - 180s "newer" - but sits at 300s, i.e. BEHIND us. That
    // combination is the clock-skew signature.
    Progress.record(BOOK, 900, 1000, false);
    Test.assertMessage(Progress.get(BOOK)[2], "fixture must be dirty");

    Progress.mergeServer(BOOK, 300, 1180, false);

    var c = Progress.conflicts();
    Test.assertMessage(c != null, "losing unflushed listening must be counted");
    Test.assertEqual(c["count"], 1);
    Test.assertEqual(c["skew"], 180);    // server ts - local ts
    Test.assertEqual(c["lost"], 600);    // how much further along we were
    // The merge itself is unchanged - this is instrumentation, not a fix.
    Test.assertEqual(Progress.get(BOOK)[0], 300);

    Progress.remove(BOOK); Progress.clearConflicts();
    logger.debug("a displaced dirty write records skew and how much was lost");
    return true;
}

(:test)
function conflictNotCountedWhenServerLoses(logger) {
    var BOOK = "__watchshelf_conflict_test__";
    Progress.remove(BOOK); Progress.clearConflicts();
    Progress.record(BOOK, 900, 2000, false);
    // Older server value: the merge rejects it, so nothing is lost and nothing
    // is counted.
    Progress.mergeServer(BOOK, 300, 1000, false);
    Test.assertEqual(Progress.get(BOOK)[0], 900);
    Test.assertMessage(Progress.conflicts() == null, "a rejected server value is not a conflict");

    Progress.remove(BOOK); Progress.clearConflicts();
    logger.debug("an older server value is rejected and not counted");
    return true;
}

(:test)
function conflictCountAccumulates(logger) {
    var BOOK = "__watchshelf_conflict_test__";
    Progress.remove(BOOK); Progress.clearConflicts();
    Progress.record(BOOK, 900, 1000, false);
    Progress.mergeServer(BOOK, 300, 1100, false);
    Progress.record(BOOK, 950, 1200, false);
    Progress.mergeServer(BOOK, 400, 1300, false);

    var c = Progress.conflicts();
    Test.assertEqual(c["count"], 2);
    // The detail always describes the LATEST occurrence, so the value stays
    // O(1) however often this fires.
    Test.assertEqual(c["skew"], 100);
    Test.assertEqual(c["lost"], 550);

    Progress.remove(BOOK); Progress.clearConflicts();
    logger.debug("the counter accumulates while the detail stays O(1)");
    return true;
}

(:test)
function conflictNotCountedForAFirstEverPull(logger) {
    var BOOK = "__watchshelf_conflict_test__";
    Progress.remove(BOOK); Progress.clearConflicts();
    // No local entry at all: the server value is simply adopted. There is no
    // local listening to lose, so this is not a conflict.
    Progress.mergeServer(BOOK, 300, 1000, false);
    Test.assertEqual(Progress.get(BOOK)[0], 300);
    Test.assertMessage(Progress.conflicts() == null, "a first pull is not a conflict");

    Progress.remove(BOOK); Progress.clearConflicts();
    logger.debug("adopting a server value with no local entry is not counted");
    return true;
}
