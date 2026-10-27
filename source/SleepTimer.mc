using Toybox.Application;
using Toybox.WatchUi;

// Sleep timer (issue #77). Toybox.Media has no pause/stop API for a content
// provider, so the only lever is the iterator: once the deadline passes,
// next() hands the player nothing and playback ends at the close of the
// current part. That overshoots by up to one part (~3 min), which is fine
// for falling asleep. The deadline lives in memory only - a fresh playback
// session (new ContentDelegate) or native resume re-arms it from the chosen
// minutes. Changing the duration during playback restarts the countdown.
module SleepTimer {
    // Minutes offered in the picker; 0 = off. Must match the listEntry
    // values in settings.xml (phone), which edits the same property.
    const ALL = [ 0, 5, 15, 20, 30, 45, 60, 90, 120 ];

    var deadline = null; // epoch seconds, null = not armed
    var sessionMinutes = null; // null until a playback delegate starts

    function minutes() {
        var m = Application.Properties.getValue(Settings.SLEEP_MINUTES);
        return (m instanceof Toybox.Lang.Number) ? m : 0;
    }

    function setMinutes(m) {
        Application.Properties.setValue(Settings.SLEEP_MINUTES, m);
        settingsChanged();
    }

    function label(m) {
        if (m <= 0) { return WatchUi.loadResource(Rez.Strings.sleepOff); }
        if ((m >= 60) && (m % 60 == 0)) { return (m / 60).toString() + "h"; }
        return m.toString() + " min";
    }

    // Called for a new playback session or a native resume after pause.
    function arm() {
        var m = minutes();
        sessionMinutes = m;
        deadline = (m > 0) ? Progress.nowSec() + (m * 60) : null;
    }

    // The phone and watch picker both edit the same property. Apply changes
    // to an existing session, including cancelling a pending deadline for
    // Off. An unrelated settings update must not extend a running countdown
    // or re-arm one that has already fired.
    function settingsChanged() {
        if ((sessionMinutes != null) && (minutes() != sessionMinutes)) {
            arm();
        }
    }

    // True exactly once when the deadline has passed, then disarms: after the
    // player stops, the user pressing play/next must keep working normally.
    function fire() {
        if (!isDue(deadline, Progress.nowSec())) { return false; }
        deadline = null;
        return true;
    }

    function isDue(d, now) {
        return (d != null) && (now >= d);
    }
}
