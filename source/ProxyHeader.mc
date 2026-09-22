using Toybox.Application;
using Toybox.Graphics;
using Toybox.Timer;
using Toybox.WatchUi;

// On-watch setup for the optional reverse-proxy header (issue #41).
//
// Someone exposing the sidecar to the internet may want their proxy to drop
// any request that doesn't carry a shared secret. This collects the header
// NAME then its VALUE and stores both, after which every watch->sidecar
// request carries them (see AbsApi.getOptions / postOptions / healthOptions
// and the audio download in SyncDelegate).
//
// It lives in the DOWNLOADED menu rather than the login flow on purpose: the
// header has to be set BEFORE a proxy will pass /health, so it must be
// reachable when the user is NOT logged in - and putting it in the login flow
// would tax the large majority who don't run a proxy with two extra screens.
//
// Entry goes through TextEntry, so this works on vivoactive4/venu (no
// WatchUi.TextPicker) exactly as it does everywhere else.
module ProxyHeader {

    // Subtitle for the menu row: the configured header name, or "Not set".
    function summary() {
        var name = AbsApi.proxyName();
        if ((name == null) || (name.length() == 0)) {
            return WatchUi.loadResource(Rez.Strings.proxyNotSet);
        }
        // The secret is never shown - only that a name is configured. A
        // shoulder-surfable secret on a menu row would defeat the point.
        return name;
    }

    // `item` is the menu row that launched this, so its subtitle can be
    // refreshed in place on save - popping back to the existing DownloadedMenu
    // would otherwise leave it reading "Not set" until the menu is rebuilt.
    function start(item) {
        WatchUi.pushView(new ProxyHeaderView(item), new LibraryViewDelegate(),
            WatchUi.SLIDE_LEFT);
    }

    function save(name, value) {
        // An empty NAME clears the whole thing - that is the "turn it off"
        // gesture, and it must also drop the secret so a later re-enable
        // can't silently reuse a forgotten one.
        if ((name == null) || (name.length() == 0)) {
            Application.Storage.deleteValue(Store.PROXY_NAME);
            Application.Storage.deleteValue(Store.PROXY_VALUE);
            return;
        }
        Application.Storage.setValue(Store.PROXY_NAME, name);
        Application.Storage.setValue(Store.PROXY_VALUE, (value != null) ? value : "");
    }
}

// Two-step collector, same shape as LoginView: show a label, open the editor
// from a TIMER once the previous one has closed (pushing the next editor from
// inside a delegate callback makes the system pop the view just pushed - see
// the Login.mc header), record the value on the way back.
class ProxyHeaderView extends WatchUi.View {
    // 0 name, 1 value, 2 save-and-leave, 3 leave without saving
    private var mState;
    private var mName;
    private var mValue;
    private var mMessage;
    private var mTimer;
    private var mItem;

    function initialize(item) {
        View.initialize();
        mItem = item;
        mState = 0;
        var n = AbsApi.proxyName();
        mName = (n != null) ? n : "X-Client-Authentication";
        mValue = "";
        mMessage = "";
        mTimer = null;
    }

    // Runs on first show and each time an editor closes.
    function onShow() {
        if (mState <= 1) {
            mMessage = WatchUi.loadResource(
                (mState == 0) ? Rez.Strings.proxyFieldName : Rez.Strings.proxyFieldValue);
            WatchUi.requestUpdate();
            mTimer = new Timer.Timer();
            mTimer.start(method(:openField), 900, false);
            return;
        }
        // Finished (2) or cancelled (3). Persist before leaving, but do the
        // LEAVING from a timer: popView from inside onShow is a re-entrant UI
        // operation that can lock the UI thread on real devices (the same trap
        // LibraryView documents for its deferred login switch).
        if (mState == 2) {
            ProxyHeader.save(mName, mValue);
            if (mItem != null) { mItem.setSubLabel(ProxyHeader.summary()); }
        }
        mTimer = new Timer.Timer();
        mTimer.start(method(:close), 100, false);
    }

    function close() {
        mTimer = null;
        var saved = (mState == 2);
        // Pop FIRST, then toast: Notify.flash falls back to pushView on
        // firmware without showToast, and flashing before the pop would make
        // this view pop the toast instead of itself.
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
        if (saved) { Notify.flash(Rez.Strings.proxySaved); }
    }

    function onHide() {
        if (mTimer != null) { mTimer.stop(); mTimer = null; }
    }

    function openField() {
        mTimer = null;
        if (mState == 0) {
            TextEntry.open(self, 0, mName,
                WatchUi.loadResource(Rez.Strings.proxyFieldName), false);
        } else if (mState == 1) {
            // Masked: it is a secret, and the wearer is in public as often as
            // not. It starts EMPTY rather than pre-filled with the stored one.
            TextEntry.open(self, 1, "",
                WatchUi.loadResource(Rez.Strings.proxyFieldValue), true);
        }
    }

    // TextEntry callbacks - same contract LoginView implements.
    function setField(field, text) {
        if (field == 0) {
            mName = text;
            // Clearing the name skips straight past the secret prompt: there is
            // nothing to attach it to.
            mState = ((text == null) || (text.length() == 0)) ? 2 : 1;
            return;
        }
        mValue = text;
        mState = 2;
    }

    // Abandon without writing anything: a half-entered header is worse than
    // none, because it would make the proxy reject every request. Does NOT pop
    // here - the editor's own delegate pops itself, and popping again would
    // take the DownloadedMenu with it. onShow then leaves via the timer.
    function cancelFlow() {
        mState = 3;
    }

    function onUpdate(dc) {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.drawText(dc.getWidth() / 2, dc.getHeight() / 2, Graphics.FONT_SMALL,
            mMessage, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }
}
