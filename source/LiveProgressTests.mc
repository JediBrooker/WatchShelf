using Toybox.Test;

// The live push worker's pull policy. The pull it performs before a push is
// what stops a stale resume position clobbering a newer position from another
// device - but PLAYBACK_NOTIFY fires every ~15s of playback, so doing it every
// time would double an hour of listening from ~240 requests to ~480 over the
// phone bridge. needsPull() is the compromise, and these pin it.

(:test)
function livePullsOnFirstExchange(logger) {
    var w = new LiveProgressWorker();
    // The first push for a book is the ONLY one a stale resume can be hiding
    // in, so it must always be preceded by a pull.
    Test.assertMessage(w.needsPull("bookA", 1000), "first exchange must pull");
    logger.debug("a book never exchanged with is always pulled first");
    return true;
}

(:test)
function liveSkipsPullWithinTtl(logger) {
    var w = new LiveProgressWorker();
    w.noteChecked("bookA", 1000);

    // Same listening session: the watch is the most recent writer, so every
    // later position is strictly newer and from this same device.
    Test.assertMessage(!w.needsPull("bookA", 1000), "no pull immediately after");
    Test.assertMessage(!w.needsPull("bookA", 1000 + 15), "not on the next notify");
    Test.assertMessage(!w.needsPull("bookA", 1000 + w.PULL_TTL - 1), "not just inside the TTL");

    // A different book has its own state and must still pull.
    Test.assertMessage(w.needsPull("bookB", 1000), "another book is unaffected");

    logger.debug("pushes within the TTL skip the round trip");
    return true;
}

(:test)
function livePullsAgainAfterTtl(logger) {
    var w = new LiveProgressWorker();
    w.noteChecked("bookA", 1000);
    // A long pause is exactly when another device may have moved on, so the
    // watch must stop assuming it is still the most recent writer.
    Test.assertMessage(w.needsPull("bookA", 1000 + w.PULL_TTL), "pull at the TTL boundary");
    Test.assertMessage(w.needsPull("bookA", 1000 + w.PULL_TTL + 600), "and well past it");
    logger.debug("the watch re-checks after a long gap");
    return true;
}

(:test)
function livePullsWhenTheClockMovesBackward(logger) {
    var w = new LiveProgressWorker();
    w.noteChecked("bookA", 5000);
    // A backward clock jump (manual set, firmware time correction) would
    // otherwise make (now - last) negative and suppress pulls until the clock
    // caught up - potentially a very long time.
    Test.assertMessage(w.needsPull("bookA", 4000), "a backward jump re-checks");
    logger.debug("a backward clock jump does not pin the throttle closed");
    return true;
}

(:test)
function liveThrottleIsPerBook(logger) {
    var w = new LiveProgressWorker();
    w.noteChecked("bookA", 1000);
    w.noteChecked("bookB", 1000 - w.PULL_TTL);   // older than the TTL
    Test.assertMessage(!w.needsPull("bookA", 1000), "A is fresh");
    Test.assertMessage(w.needsPull("bookB", 1000), "B is stale and pulls");
    logger.debug("each book carries its own freshness");
    return true;
}
