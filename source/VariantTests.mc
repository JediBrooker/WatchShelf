using Toybox.Application;
using Toybox.Test;

// Playback-speed variants: a book may hold TWO encodings of the same audio so
// that switching back to one already on the watch is instant. The tempo is
// baked in by the sidecar - Toybox.Media has no playback-rate API - so this is
// the only way a speed change can ever be free.

(:test)
function variantLegacyBookReadsAsPrimary(logger) {
    var B = "__ws_var_legacy__";
    BookStore.deleteBook(B);
    // A record written before variants existed: no alt, no active, and (older
    // still) no speed either. It must read as 1.0x on the primary slot, with
    // its pages at the ORIGINAL key - that is what makes this migration-free.
    Application.Storage.setValue("trk:" + B,
        { "title" => "Old", "author" => "T", "durs" => [3600], "first" => 0 });
    Application.Storage.setValue("trkc:" + B + ":0", ["r0", "r1"]);

    Test.assertEqual(BookStore.activeSlot(B), BookStore.SLOT_PRIMARY);
    Test.assertEqual(BookStore.activeSpeed(B), 100);
    Test.assertEqual(BookStore.count(B), 2);
    Test.assertEqual(BookStore.first(B), 0);
    Test.assertEqual(BookStore.pageKey(B, 0), "trkc:" + B + ":0");

    BookStore.deleteBook(B);
    logger.debug("a pre-variant record needs no migration");
    return true;
}

(:test)
function variantSwitchBackIsInstant(logger) {
    var B = "__ws_var_switch__";
    BookStore.deleteBook(B);
    BookStore.ensureMeta(B, "Book", "T", [3600], 0, 100);
    Application.Storage.setValue("trkc:" + B + ":0", ["p0", "p1"]);   // 1.0x

    // Switch to 1.5x: the 1.0x encoding is parked, and the new slot is active
    // and empty, ready for its download.
    var slot = BookStore.beginVariant(B, 150, 0, true);
    Test.assertEqual(slot, BookStore.SLOT_ALT);
    Test.assertEqual(BookStore.activeSpeed(B), 150);
    Test.assertEqual(BookStore.count(B), 0);
    Application.Storage.setValue("trkc:" + B + ":a:0", ["a0", "a1", "a2"]);
    Test.assertEqual(BookStore.count(B), 3);

    // The whole point: 1.0x is still held, so going back costs nothing.
    Test.assertMessage(BookStore.slotForSpeed(B, 100) >= 0, "1.0x is still held");
    Test.assertMessage(BookStore.switchTo(B, 100), "switching back must succeed");
    Test.assertEqual(BookStore.activeSpeed(B), 100);
    Test.assertEqual(BookStore.count(B), 2);          // the ORIGINAL chunks
    Test.assertMessage(BookStore.switchTo(B, 150), "and forward again");
    Test.assertEqual(BookStore.count(B), 3);

    // A speed nobody downloaded cannot be switched to.
    Test.assertMessage(!BookStore.switchTo(B, 200), "2.0x was never fetched");

    BookStore.deleteBook(B);
    logger.debug("switching between held encodings is instant and lossless");
    return true;
}

// THE dangerous one. sweepOrphans() evicts cached audio that no book's records
// claim. If addRefIds reported only the ACTIVE variant, the parked encoding
// would be swept at the very next sync - silently destroying the copy the user
// is spending storage to keep, and turning the instant switch back into a full
// re-download.
(:test)
function variantParkedCopySurvivesTheOrphanSweep(logger) {
    var B = "__ws_var_sweep__";
    BookStore.deleteBook(B);
    BookStore.ensureMeta(B, "Book", "T", [3600], 0, 100);
    Application.Storage.setValue("trkc:" + B + ":0", ["slow0", "slow1"]);
    BookStore.beginVariant(B, 200, 0, true);
    Application.Storage.setValue("trkc:" + B + ":a:0", ["fast0"]);

    var known = {};
    BookStore.addRefIds(B, known);

    Test.assertMessage(known["fast0"] != null, "active variant is claimed");
    Test.assertMessage(known["slow0"] != null, "PARKED variant must also be claimed");
    Test.assertMessage(known["slow1"] != null, "every parked chunk, not just the first");

    BookStore.deleteBook(B);
    logger.debug("the sweep sees both encodings, so the parked one is safe");
    return true;
}

(:test)
function variantReplaceWhenThereIsNoRoom(logger) {
    var B = "__ws_var_replace__";
    BookStore.deleteBook(B);
    BookStore.ensureMeta(B, "Book", "T", [3600], 0, 100);
    Application.Storage.setValue("trkc:" + B + ":0", ["p0", "p1"]);

    // keepOther=false is what the caller passes when parking both would breach
    // Chunks.MAX_TOTAL: the old encoding is evicted and the SAME slot reused,
    // which is exactly the pre-variant behaviour.
    var slot = BookStore.beginVariant(B, 150, 0, false);
    Test.assertEqual(slot, BookStore.SLOT_PRIMARY);
    Test.assertEqual(BookStore.activeSpeed(B), 150);
    Test.assertEqual(BookStore.count(B), 0);
    Test.assertMessage(BookStore.slotForSpeed(B, 100) < 0, "1.0x is gone, as intended");
    Test.assertEqual(BookStore.totalChunks(B), 0);

    BookStore.deleteBook(B);
    logger.debug("no room means replace, degrading to the old behaviour");
    return true;
}

(:test)
function variantDeleteRemovesBothAndCapCountsBoth(logger) {
    var B = "__ws_var_delete__";
    BookStore.deleteBook(B);
    BookStore.ensureMeta(B, "Book", "T", [3600], 0, 100);
    Application.Storage.setValue("trkc:" + B + ":0", ["p0", "p1"]);
    BookStore.beginVariant(B, 150, 0, true);
    Application.Storage.setValue("trkc:" + B + ":a:0", ["a0", "a1", "a2"]);

    // The cap must see BOTH encodings - a parked variant is still cached audio,
    // and counting only the active one would quietly overrun the ceiling the
    // cap exists to defend.
    Test.assertEqual(BookStore.count(B), 3);          // active only
    Test.assertEqual(BookStore.totalChunks(B), 5);    // both

    BookStore.deleteBook(B);
    Test.assertEqual(BookStore.totalChunks(B), 0);
    Test.assertMessage(Application.Storage.getValue("trkc:" + B + ":0") == null, "primary pages gone");
    Test.assertMessage(Application.Storage.getValue("trkc:" + B + ":a:0") == null, "alternate pages gone");
    Test.assertMessage(BookStore.get(B) == null, "metadata gone");

    logger.debug("delete clears both encodings; the cap counts both");
    return true;
}

// Re-downloading the SAME speed must reuse its own slot rather than parking a
// copy of the thing it is replacing - otherwise a retry would consume the
// second slot and evict the genuinely different encoding held there.
(:test)
function variantSameSpeedRedownloadReusesItsSlot(logger) {
    var B = "__ws_var_same__";
    BookStore.deleteBook(B);
    BookStore.ensureMeta(B, "Book", "T", [3600], 0, 100);
    Application.Storage.setValue("trkc:" + B + ":0", ["p0"]);
    BookStore.beginVariant(B, 150, 0, true);          // 1.0x parked, 1.5x active
    Application.Storage.setValue("trkc:" + B + ":a:0", ["a0"]);

    var slot = BookStore.beginVariant(B, 150, 0, true);   // retry 1.5x
    Test.assertEqual(slot, BookStore.SLOT_ALT);
    Test.assertMessage(BookStore.slotForSpeed(B, 100) >= 0, "1.0x must NOT be evicted");

    BookStore.deleteBook(B);
    logger.debug("a same-speed retry does not consume the other slot");
    return true;
}
