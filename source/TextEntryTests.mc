using Toybox.Test;

// The fallback keyboard's state machine, exercised without a Dc. Everything
// asserted here is what a vivoactive4 user's clicks actually drive. Compiled
// only for Run No Evil (`monkeyc -t`), so it costs device builds nothing.
//
// Wheel layout, for all of the index arithmetic below:
//   0 DONE | 1 DEL | 2 MODE | 3.. the current set's characters
// Lowercase therefore has count() == 3 + 26 == 29, and a fresh view sits on
// position 3 ('a').

(:test)
function keyboardWheelWraps(logger) {
    var v = new CharPickerView("Username", "", false);

    // Opens on the first CHARACTER, not on an action, so clicking straight
    // through types letters instead of finishing the field by accident.
    Test.assertEqual(v.glyph(), "a");

    v.move(1);
    Test.assertEqual(v.glyph(), "b");            // pos 4

    v.move(-4);                                   // pos 0
    Test.assertMessage(v.activate(), "position 0 is DONE");

    // Backward past 0 must wrap to the END, not to a negative index: Monkey C's
    // % keeps the dividend's sign, so this is exactly what a naive
    // (pos - 1) % n gets wrong.
    v.move(-1);
    Test.assertEqual(v.glyph(), "z");            // pos 28, last of the set

    v.move(1);                                    // 29 wraps to 0
    Test.assertMessage(v.activate(), "wrapping forward off the end lands on DONE");

    logger.debug("wheel wraps both ways; DONE is one step back from 'a'");
    return true;
}

(:test)
function keyboardTypesAndDeletes(logger) {
    var v = new CharPickerView("Username", "", false);

    Test.assertMessage(!v.activate(), "appending a character is not DONE");
    v.move(1);                                    // 'a' -> 'b'
    v.activate();
    Test.assertEqual(v.text(), "ab");

    v.move(-3);                                   // pos 4 -> pos 1 == DEL
    Test.assertMessage(!v.activate(), "DEL is not DONE");
    Test.assertEqual(v.text(), "a");
    v.activate();
    Test.assertEqual(v.text(), "");
    v.activate();
    Test.assertEqual(v.text(), "");              // deleting nothing is harmless

    logger.debug("characters append; DEL backs off without underflowing");
    return true;
}

(:test)
function keyboardModeSwitchRebasesPosition(logger) {
    // The sets differ in length (26/26/10/20), so switching must land on a
    // position that EXISTS in the new set - keeping a stale index is how this
    // would read off the end of "0123456789".
    var v = new CharPickerView("URL", "", false);
    Test.assertEqual(v.count(), 3 + 26);

    v.move(-1);                                   // pos 3 -> pos 2 == MODE
    Test.assertMessage(!v.activate(), "MODE is not DONE");
    Test.assertEqual(v.glyph(), "A");
    Test.assertEqual(v.count(), 3 + 26);

    v.move(-1); v.activate();
    Test.assertEqual(v.glyph(), "0");
    Test.assertEqual(v.count(), 3 + 10);

    v.move(-1); v.activate();
    Test.assertEqual(v.glyph(), ".");
    Test.assertEqual(v.count(), 3 + 20);

    v.move(-1); v.activate();                     // full cycle, back to lowercase
    Test.assertEqual(v.glyph(), "a");
    Test.assertEqual(v.count(), 3 + 26);

    logger.debug("mode switch rebases onto the new set's first character");
    return true;
}

(:test)
function keyboardMasksAndTruncates(logger) {
    // A password is never echoed back on screen.
    Test.assertEqual(new CharPickerView("Password", "hunter2", true).display(), "*******");

    // An empty field shows a caret rather than nothing at all.
    Test.assertEqual(new CharPickerView("Username", "", false).display(), "_");

    // Long values show their TAIL - the characters just typed, which are the
    // ones being checked - behind an ellipsis. 25 chars, keeping the last 16.
    Test.assertEqual(
        new CharPickerView("URL", "https://books.example.com", false).display(),
        "...ooks.example.com");

    // Exactly at the cut-off, nothing is trimmed.
    Test.assertEqual(new CharPickerView("URL", "0123456789abcdef", false).display(),
        "0123456789abcdef");

    logger.debug("password masked, empty shows a caret, long values show the tail");
    return true;
}

(:test)
function keyboardStopsAtMaxLength(logger) {
    var long = "";
    for (var i = 0; i < TextEntry.MAX_LEN; ++i) { long = long + "a"; }

    var v = new CharPickerView("URL", long, false);
    Test.assertEqual(v.text().length(), TextEntry.MAX_LEN);
    v.activate();                                 // try to append one more
    Test.assertEqual(v.text().length(), TextEntry.MAX_LEN);

    // DEL still works at the cap, so the field can never become unrecoverable.
    v.move(-2);                                   // pos 3 -> pos 1 == DEL
    v.activate();
    Test.assertEqual(v.text().length(), TextEntry.MAX_LEN - 1);

    logger.debug("input is bounded, and remains editable at the bound");
    return true;
}
