using Toybox.Graphics;
using Toybox.WatchUi;

// On-watch text entry that works on EVERY device in manifest.xml.
//
// WatchUi.TextPicker - the system keyboard - is NOT universal. Checked against
// the installed device API manifests in SDK 9.2.0 (Devices/<id>/<id>.api.debug.xml,
// the compiler's own contract rather than docs): vivoactive4, vivoactive4s,
// venu and venud ship WatchUi.TextPickerDelegate but NOT WatchUi.TextPicker.
// So `new WatchUi.TextPicker(...)` raised
//
//     Symbol Not Found Error ... openField() at source/Login.mc:97
//
// and killed login before a single character could be typed (issue #48). The
// other 50 products have both. Note it is ONLY the picker that is missing -
// TextPickerDelegate resolves everywhere - so FieldDelegate below stays
// compiled and referenced on every device; only the `new TextPicker` call
// needs guarding.
//
// The fallback is CharPickerView, a character wheel driven entirely by
// BehaviorDelegate BEHAVIORS rather than raw key events. That matters: the
// behaviors map to the up/down/start buttons on a button watch AND to
// swipe-down/swipe-up/tap on a touch watch, so one implementation covers both
// without device branching. (Per the SDK: onNextPage <- down key or SWIPE_UP,
// onPreviousPage <- up key or SWIPE_DOWN, onSelect <- start key or tap. A
// behavior returning true suppresses the matching InputDelegate callback, so
// a tap cannot be counted twice.)
module TextEntry {

    // Character sets the wheel cycles through, and their short mode names.
    // Split into four short sets deliberately: one flat set of ~90 glyphs
    // would be unusable a-click-at-a-time, and the URL/e-mail punctuation
    // people actually need is in reach in the last one.
    const SETS = [
        "abcdefghijklmnopqrstuvwxyz",
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
        "0123456789",
        ".:/-_@~?=&%+#!$*,'()"
    ];
    const MODES = [ "abc", "ABC", "123", "#+=" ];

    // Wheel positions 0..2 are actions, everything after is a character of the
    // current set. DONE sits at 0 so it is one step BACKWARD from the start of
    // the alphabet - the wheel wraps, so finishing is always one click away.
    const ACT_DONE = 0;
    const ACT_DEL  = 1;
    const ACT_MODE = 2;
    const ACTIONS  = 3;

    // Longer than any realistic URL or passphrase, and bounded so a stuck
    // input cannot grow a String until the 512KB heap complains.
    const MAX_LEN = 128;

    function hasSystemKeyboard() {
        return WatchUi has :TextPicker;
    }

    // Open an editor for one login field. `owner` is the LoginView: it gets
    // setField(field, text) on accept and cancelFlow() on cancel, exactly as
    // the system keyboard path does, so the caller cannot tell which was used.
    function open(owner, field, initial, prompt, masked) {
        if (hasSystemKeyboard()) {
            WatchUi.pushView(new WatchUi.TextPicker(initial),
                new FieldDelegate(owner, field), WatchUi.SLIDE_LEFT);
            return;
        }
        var view = new CharPickerView(prompt, initial, masked);
        WatchUi.pushView(view, new CharPickerDelegate(view, owner, field),
            WatchUi.SLIDE_LEFT);
    }
}

// System-keyboard delegate. Records the value + advances state, then returns
// true so THIS keyboard closes. Do NOT push the next keyboard here: returning
// true makes the system pop the TOP view, which would be the keyboard just
// pushed ("checkmark does nothing"). LoginView.onShow opens the next field
// from a timer once this one has closed.
class FieldDelegate extends WatchUi.TextPickerDelegate {
    private var mOwner;
    private var mField;
    function initialize(owner, field) {
        TextPickerDelegate.initialize();
        mOwner = owner;
        mField = field;
    }
    function onTextEntered(text, changed) {
        mOwner.setField(mField, text);
        return true;
    }
    function onCancel() {
        mOwner.cancelFlow();
        return true;
    }
}

// The fallback keyboard: one glyph at a time off a wrapping wheel.
class CharPickerView extends WatchUi.View {
    private var mPrompt;
    private var mText;
    private var mMasked;
    private var mMode;
    private var mPos;

    function initialize(prompt, initial, masked) {
        View.initialize();
        mPrompt = (prompt != null) ? prompt : "";
        mText = (initial != null) ? initial : "";
        mMasked = (masked == true);
        mMode = 0;
        mPos = TextEntry.ACTIONS;   // first real character, not an action
    }

    function text() { return mText; }

    function count() {
        return TextEntry.ACTIONS + TextEntry.SETS[mMode].length();
    }

    // Wrapping move. Monkey C's % keeps the sign of the dividend, so a
    // backward step past 0 needs the explicit + count.
    function move(step) {
        var n = count();
        mPos = ((mPos + step) % n + n) % n;
        WatchUi.requestUpdate();
    }

    // Act on the current wheel position. Returns true only when the user
    // chose DONE, which is the delegate's cue to hand the text back.
    function activate() {
        if (mPos == TextEntry.ACT_DONE) { return true; }
        if (mPos == TextEntry.ACT_DEL) {
            if (mText.length() > 0) {
                mText = mText.substring(0, mText.length() - 1);
            }
        } else if (mPos == TextEntry.ACT_MODE) {
            mMode = (mMode + 1) % TextEntry.SETS.size();
            // Sets differ in length, so land on the new set's first character
            // rather than an index that may no longer exist.
            mPos = TextEntry.ACTIONS;
        } else if (mText.length() < TextEntry.MAX_LEN) {
            mText = mText + glyph();
        }
        WatchUi.requestUpdate();
        return false;
    }

    // The character under the wheel, for positions past the actions.
    function glyph() {
        var i = mPos - TextEntry.ACTIONS;
        var set = TextEntry.SETS[mMode];
        if ((i < 0) || (i >= set.length())) { return ""; }
        return set.substring(i, i + 1);
    }

    // What to render at the wheel: an action's name, or the character.
    function label() {
        if (mPos == TextEntry.ACT_DONE) { return WatchUi.loadResource(Rez.Strings.kbDone); }
        if (mPos == TextEntry.ACT_DEL)  { return WatchUi.loadResource(Rez.Strings.kbDelete); }
        if (mPos == TextEntry.ACT_MODE) {
            return TextEntry.MODES[(mMode + 1) % TextEntry.SETS.size()];
        }
        return glyph();
    }

    // The entered text, masked for a password and tail-truncated so the most
    // recently typed characters - the ones being checked - stay visible.
    function display() {
        var s = mText;
        if (mMasked) {
            var stars = "";
            for (var i = 0; i < s.length(); ++i) { stars = stars + "*"; }
            s = stars;
        }
        if (s.length() == 0) { return "_"; }
        if (s.length() > 16) { return "..." + s.substring(s.length() - 16, s.length()); }
        return s;
    }

    function onUpdate(dc) {
        var w = dc.getWidth();
        var h = dc.getHeight();
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        // Which field is being typed.
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h * 18 / 100, Graphics.FONT_XTINY, mPrompt,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // What has been entered so far.
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h * 35 / 100, Graphics.FONT_SMALL, display(),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // The wheel. Chevrons make it discoverable that this scrolls, without
        // needing per-device wording for buttons vs swipes.
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w * 22 / 100, h * 58 / 100, Graphics.FONT_SMALL, "<",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(w * 78 / 100, h * 58 / 100, Graphics.FONT_SMALL, ">",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h * 58 / 100, Graphics.FONT_LARGE, label(),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Current mode, so it is obvious what the mode key will leave behind.
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h * 80 / 100, Graphics.FONT_XTINY,
            TextEntry.MODES[mMode],
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }
}

// Behaviors only - see the TextEntry header for why this covers buttons and
// touch at once.
class CharPickerDelegate extends WatchUi.BehaviorDelegate {
    private var mView;
    private var mOwner;
    private var mField;

    function initialize(view, owner, field) {
        BehaviorDelegate.initialize();
        mView = view;
        mOwner = owner;
        mField = field;
    }

    function onNextPage()     { mView.move(1);  return true; }
    function onPreviousPage() { mView.move(-1); return true; }

    // Unlike the system keyboard - which the OS pops for us when the delegate
    // returns true - nothing pops this view on its own, so accept and cancel
    // both pop explicitly. Either way LoginView.onShow runs next and drives
    // the flow on, so the two paths are indistinguishable to the caller.
    function onSelect() {
        if (mView.activate()) {
            mOwner.setField(mField, mView.text());
            WatchUi.popView(WatchUi.SLIDE_RIGHT);
        }
        return true;
    }

    function onBack() {
        mOwner.cancelFlow();
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
        return true;
    }
}
