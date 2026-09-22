using Toybox.Application;
using Toybox.Communications;
using Toybox.Media;
using Toybox.WatchUi;

// Per-book actions, reached from PlayMenu. Resume / Play from start hand the
// chosen book + mode to the native player via Media.startPlayback(args); the
// ContentIterator reads {item, mode} to position its cursor (see
// ContentIterator.applyStart). Delete queues this one book for removal, exactly
// like the old top-level book-row tap did.
class BookActionMenu extends WatchUi.Menu2 {

    function initialize(itemId, title) {
        Menu2.initialize({ :title => title });
        // A completed book has no meaningful resume cursor: offering it was
        // the UI half of the old "last part repeats" bug. Start-over remains
        // available and immediately clears finished once playback is reported.
        if (!Progress.isFinished(itemId)) {
            addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.resume), null, "resume", null));
        }
        // Tail-only downloads cannot literally start at 0. Name the action for
        // what the player can do: begin at the earliest downloaded part.
        var startLabel = (BookStore.first(itemId) > 0)
            ? Rez.Strings.playFromDownloadedStart : Rez.Strings.playFromStart;
        addItem(new WatchUi.MenuItem(WatchUi.loadResource(startLabel), null, "start", null));
        // Playback speed lives HERE, on a book you already have, rather than
        // only at download time. The tempo is baked into the audio by the
        // sidecar (Toybox.Media has no playback-rate API at all), so a speed
        // the watch does not already hold still has to be fetched - but the
        // previous encoding is kept when there is room, which makes switching
        // back to it instant. See BookStore's variant layer.
        addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.playbackSpeed),
            PlaybackSpeed.label(BookStore.activeSpeed(itemId)), "speed", null));
        addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.deleteBook), null, "delete", null));
    }
}

// Speed picker for a book already on the watch. A speed the watch HOLDS is
// marked and switches instantly; anything else has to be fetched.
class BookSpeedChoiceMenu extends WatchUi.Menu2 {
    function initialize(itemId) {
        Menu2.initialize({ :title => WatchUi.loadResource(Rez.Strings.playbackSpeed) });
        var active = BookStore.activeSpeed(itemId);
        for (var i = 0; i < PlaybackSpeed.ALL.size(); ++i) {
            var sp = PlaybackSpeed.ALL[i];
            var sub = null;
            if (sp == active) {
                sub = WatchUi.loadResource(Rez.Strings.speedCurrent);
            } else if (BookStore.slotForSpeed(itemId, sp) >= 0) {
                // Held on the watch: choosing it costs nothing.
                sub = WatchUi.loadResource(Rez.Strings.speedReady);
            }
            addItem(new WatchUi.MenuItem(PlaybackSpeed.label(sp), sub, sp.toString(), null));
        }
    }
}

class BookSpeedChoiceDelegate extends WatchUi.Menu2InputDelegate {
    private var mItemId;

    function initialize(itemId) {
        Menu2InputDelegate.initialize();
        mItemId = itemId;
    }

    function onSelect(item) {
        var speed = PlaybackSpeed.normalize(item.getId().toNumber());
        WatchUi.popView(WatchUi.SLIDE_RIGHT);

        // Already the active encoding - nothing to do.
        if (speed == BookStore.activeSpeed(mItemId)) { return; }

        // Held in the other slot: instant, no download. This is the whole
        // point of parking the previous encoding.
        if (BookStore.switchTo(mItemId, speed)) {
            Notify.flash(Rez.Strings.speedSwitched);
            return;
        }

        // Not held - it must be fetched. Say so before committing, because the
        // audio for a speed cannot be produced on the watch.
        WatchUi.pushView(
            new WatchUi.Confirmation(WatchUi.loadResource(Rez.Strings.confirmSpeedFetch)),
            new SpeedFetchConfirmDelegate(mItemId, speed), WatchUi.SLIDE_LEFT);
    }

    function onBack() {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
}

class SpeedFetchConfirmDelegate extends WatchUi.ConfirmationDelegate {
    private var mItemId;
    private var mSpeed;
    function initialize(itemId, speed) {
        ConfirmationDelegate.initialize();
        mItemId = itemId;
        mSpeed = speed;
    }
    function onResponse(response) {
        if (response == WatchUi.CONFIRM_YES) {
            // Reuses the ordinary download path, which already resolves the
            // file list, the resume cursor and every cap - it just carries a
            // different speed.
            new BookMenuDelegate().downloadAtSpeed(mItemId, mSpeed);
        }
        return true;
    }
}

class BookActionMenuDelegate extends WatchUi.Menu2InputDelegate {

    private var mItemId;

    function initialize(itemId) {
        Menu2InputDelegate.initialize();
        mItemId = itemId;
    }

    function onSelect(item) {
        var id = item.getId();

        if ((id instanceof Toybox.Lang.String) && id.equals("speed")) {
            WatchUi.pushView(new BookSpeedChoiceMenu(mItemId),
                new BookSpeedChoiceDelegate(mItemId), WatchUi.SLIDE_LEFT);
            return;
        }

        // Resume from the synced position; Play from start begins at 0. Both pass
        // the book id + mode to the native player, which launches playback mode
        // and hands the args to our ContentDelegate/ContentIterator.
        if ((id instanceof Toybox.Lang.String) && id.equals("resume")) {
            launchPlayback("resume");
            return;
        }
        if ((id instanceof Toybox.Lang.String) && id.equals("start")) {
            launchPlayback("start");
            return;
        }

        // Delete this one book (shared path: queue + sync, evicts the chunks).
        // A single book is far less destructive than "delete all", so no extra
        // confirm here. Pop back to the book list afterwards.
        if ((id instanceof Toybox.Lang.String) && id.equals("delete")) {
            Downloads.queueDelete([mItemId]);
            WatchUi.popView(WatchUi.SLIDE_RIGHT);
            return;
        }
    }

    function launchPlayback(mode) {
        // The native player can retain its current cached Content when this
        // provider is already active, even though startPlayback supplies a new
        // delegate payload. Stop that app-owned session first so selecting a
        // different book cannot resume the previous book's final/current part.
        // stopPlayback arrived after our minimum API, so keep older supported
        // devices on the legacy start-only path.
        if (Media has :stopPlayback) { Media.stopPlayback(); }
        Media.startPlayback({ "item" => mItemId, "mode" => mode });
    }

    function onBack() {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
}
