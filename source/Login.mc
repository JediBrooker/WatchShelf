using Toybox.Communications;
using Toybox.Graphics;
using Toybox.Timer;
using Toybox.WatchUi;

// On-watch login. For each field we show a label ("WatchShelf URL", "Username",
// "Password") for ~1s, then auto-open the keyboard for it - so the user knows
// what they're typing without an extra button press. Each field's value is
// recorded when the keyboard closes; LoginView.onShow then shows the next field.
//
// We must NOT push the next keyboard from inside onTextEntered: returning true
// there makes the system pop the TOP view, which would be the keyboard we just
// pushed ("checkmark does nothing"). So the keyboard is opened from a timer
// callback AFTER the previous one has closed.

class LoginCreds {
    var server; var username; var password;
    function initialize() { server = ""; username = ""; password = ""; }
}

module Login {
    function start() {
        WatchUi.pushView(new LoginView(), new LibraryViewDelegate(), WatchUi.SLIDE_LEFT);
    }
    // ABS reported our session dead (401). Drop the stale token (keep the server
    // URL) and restart login, so a data screen recovers cleanly instead of
    // dead-ending on "Could not load..." or a -300 hang. This is the one action
    // that actually fixes an expired session, surfaced automatically.
    function reauth() {
        AbsApi.clearToken();
        start();
    }
}

class LoginView extends WatchUi.View {
    private var mState;   // 0 server, 1 username, 2 password, 3 submit, 4 waiting, 99 error
    private var mCreds;
    private var mMessage;
    private var mTimer;

    function initialize() {
        View.initialize();
        mState = 0;
        mCreds = new LoginCreds();
        var s = AbsApi.serverUrl();
        mCreds.server = (s == null) ? "https://" : s;
        mMessage = "";
        mTimer = null;
    }

    // Runs on first show and each time a keyboard closes.
    function onShow() {
        if (mState <= 2) {
            mMessage = labelFor(mState);
            WatchUi.requestUpdate();
            mTimer = new Timer.Timer();
            mTimer.start(method(:openField), 900, false);   // show label, then open keyboard
        } else if (mState == 3) {
            mState = 4;
            mMessage = WatchUi.loadResource(Rez.Strings.loggingIn);
            WatchUi.requestUpdate();
            // Preflight the URL before sending credentials anywhere: ABS's own
            // /login would happily accept them and return a token, and the
            // mistake would only surface later as an opaque -400. /health
            // answering exactly "ok" is the sidecar's fingerprint.
            AbsApi.checkHealth(mCreds.server, method(:onHealth));
        }
        // state 4 (waiting) / 99 (error): message already set, do nothing.
    }

    function onHealth(code, data) {
        if (code == 200 && (data instanceof Toybox.Lang.String) && data.equals("ok")) {
            AbsApi.login(mCreds.server, mCreds.username, mCreds.password, method(:onLogin));
        } else {
            mState = 99;
            mMessage = Errors.message(Rez.Strings.errNotWatchShelf, code);
            WatchUi.requestUpdate();
        }
    }

    function onHide() {
        if (mTimer != null) { mTimer.stop(); mTimer = null; }
    }

    function labelFor(state) {
        if (state == 0) { return WatchUi.loadResource(Rez.Strings.fieldServer); }
        if (state == 1) { return WatchUi.loadResource(Rez.Strings.fieldUser); }
        return WatchUi.loadResource(Rez.Strings.fieldPass);
    }

    // Timer callback: open the keyboard for the current field.
    function openField() {
        mTimer = null;
        if (mState == 0) {
            WatchUi.pushView(new WatchUi.TextPicker(mCreds.server), new FieldDelegate(self, 0), WatchUi.SLIDE_LEFT);
        } else if (mState == 1) {
            WatchUi.pushView(new WatchUi.TextPicker(mCreds.username), new FieldDelegate(self, 1), WatchUi.SLIDE_LEFT);
        } else if (mState == 2) {
            WatchUi.pushView(new WatchUi.TextPicker(""), new FieldDelegate(self, 2), WatchUi.SLIDE_LEFT);
        }
    }

    function onUpdate(dc) {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.drawText(dc.getWidth() / 2, dc.getHeight() / 2, Graphics.FONT_SMALL,
            mMessage, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // Called by a FieldDelegate when a field is confirmed.
    function setField(field, text) {
        if (field == 0) { mCreds.server = text; }
        else if (field == 1) { mCreds.username = text; }
        else if (field == 2) { mCreds.password = text; }
        mState = field + 1;
    }

    function cancelFlow() {
        mState = 99;
        mMessage = WatchUi.loadResource(Rez.Strings.logIn);
        WatchUi.requestUpdate();
    }

    function onLogin(code, data) {
        if (code == 200 && data != null && data["user"] != null && data["user"]["token"] != null) {
            AbsApi.saveLogin(mCreds.server, data["user"]["token"]);
            WatchUi.switchToView(new LibraryView(), new LibraryViewDelegate(), WatchUi.SLIDE_LEFT);
        } else {
            mState = 99;
            mMessage = Errors.message(Rez.Strings.loginFailed, code);
            WatchUi.requestUpdate();
        }
    }
}

class FieldDelegate extends WatchUi.TextPickerDelegate {
    private var mView;
    private var mField;
    function initialize(view, field) {
        TextPickerDelegate.initialize();
        mView = view;
        mField = field;
    }
    // Record the value + advance state, then return true so THIS keyboard closes.
    // Do NOT push the next keyboard here (see file header).
    function onTextEntered(text, changed) {
        mView.setField(mField, text);
        return true;
    }
    function onCancel() {
        mView.cancelFlow();
        return true;
    }
}
