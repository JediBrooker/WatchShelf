using Toybox.Application;
using Toybox.Media;
using Toybox.Test;

(:test)
function sleepTimerIsDue(logger) {
    Test.assert(!SleepTimer.isDue(null, 1000));
    Test.assert(!SleepTimer.isDue(1000, 999));
    Test.assert(SleepTimer.isDue(1000, 1000));
    Test.assert(SleepTimer.isDue(1000, 5000));
    logger.debug("unarmed never fires; armed fires at and after the deadline");
    return true;
}

(:test)
function sleepTimerFiresOnce(logger) {
    SleepTimer.deadline = 1;
    Test.assert(SleepTimer.fire());
    Test.assert(!SleepTimer.fire());
    Test.assert(SleepTimer.deadline == null);
    logger.debug("expiry stops one part, then playback continues normally");
    return true;
}

(:test)
function sleepTimerLabels(logger) {
    Test.assertEqual(SleepTimer.label(5), "5 min");
    Test.assertEqual(SleepTimer.label(60), "1h");
    Test.assertEqual(SleepTimer.label(90), "90 min");
    Test.assertEqual(SleepTimer.label(120), "2h");
    logger.debug("watch labels stay short; whole hours read as h");
    return true;
}

(:test)
function sleepTimerMinutesUsePhoneProperty(logger) {
    SleepTimer.setMinutes(30);
    Test.assertEqual(Application.Properties.getValue(Settings.SLEEP_MINUTES), 30);
    Test.assertEqual(SleepTimer.minutes(), 30);
    SleepTimer.setMinutes(0);
    Test.assertEqual(SleepTimer.minutes(), 0);
    logger.debug("watch menu and phone settings share one property");
    return true;
}

(:test)
function sleepTimerSettingChangesApplyToActiveSession(logger) {
    var saved = Application.Properties.getValue(Settings.SLEEP_MINUTES);
    SleepTimer.setMinutes(5);
    SleepTimer.arm();

    // Watch picker: Off must cancel even a deadline that is already due.
    SleepTimer.deadline = 1;
    SleepTimer.setMinutes(0);
    Test.assert(SleepTimer.deadline == null);
    Test.assert(!SleepTimer.fire());

    // Phone update: the settings callback starts the newly selected duration.
    Application.Properties.setValue(Settings.SLEEP_MINUTES, 30);
    SleepTimer.settingsChanged();
    Test.assert(SleepTimer.deadline >= Progress.nowSec() + 1799);
    Test.assert(SleepTimer.deadline <= Progress.nowSec() + 1800);

    // Editing some other setting must not move a sleep deadline.
    SleepTimer.deadline = 123;
    SleepTimer.settingsChanged();
    Test.assertEqual(SleepTimer.deadline, 123);
    Test.assert(SleepTimer.fire());
    SleepTimer.settingsChanged();
    Test.assert(SleepTimer.deadline == null);

    Application.Properties.setValue(Settings.SLEEP_MINUTES, 0);
    SleepTimer.settingsChanged();
    Test.assert(!SleepTimer.fire());
    Application.Properties.setValue(Settings.SLEEP_MINUTES, saved);
    SleepTimer.deadline = null;
    SleepTimer.sessionMinutes = null;
    logger.debug("watch and phone duration changes apply; unrelated settings do not re-arm");
    return true;
}

(:test)
function sleepTimerNativeResumeRestartsWithoutResettingEachPart(logger) {
    var saved = Application.Properties.getValue(Settings.SLEEP_MINUTES);
    SleepTimer.setMinutes(5);
    var delegate = new ContentDelegate({ "item" => "__sleep_test__", "mode" => "start" });
    Test.assert(SleepTimer.deadline != null);

    // A native Resume reuses the delegate after the old deadline has elapsed.
    SleepTimer.deadline = 1;
    delegate.onSong("__sleep_ref__", Media.SONG_EVENT_RESUME, 40);
    Test.assert(SleepTimer.deadline >= Progress.nowSec() + 299);
    Test.assert(SleepTimer.deadline <= Progress.nowSec() + 300);

    SleepTimer.deadline = 123;
    delegate.onSong("__sleep_ref__", Media.SONG_EVENT_START, 0);
    Test.assertEqual(SleepTimer.deadline, 123);
    Test.assert(SleepTimer.fire());

    Application.Properties.setValue(Settings.SLEEP_MINUTES, saved);
    SleepTimer.deadline = null;
    SleepTimer.sessionMinutes = null;
    logger.debug("native resume re-arms; ordinary part START does not extend the timer");
    return true;
}
