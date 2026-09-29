using Toybox.Application;
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
