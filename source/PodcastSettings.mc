using Toybox.Application;
using Toybox.Lang;
using Toybox.WatchUi;

// Small independent records: at most ten enabled shows, one ownership record
// per episode. Old downloads without an owner are always manual. Config and
// ownership generations are distinct: editing a show invalidates discovery,
// while its already-downloaded automatic episodes remain eligible for retention.
module PodcastSettings {
    const INDEX = "podShows";
    const EPOCH = "podEpoch";
    const SCOPE = "podScope";
    const MAX_SHOWS = 10;
    const MAX_SUPPRESSED = 20;

    function key(show) { return "podShow:" + show; }
    function ownerKey(itemId) { return "podOwn:" + itemId; }
    function epoch() {
        var value = Application.Storage.getValue(EPOCH);
        return (value instanceof Lang.Number) ? value : 0;
    }
    function cancelPending() {
        var next = epoch() + 1;
        Application.Storage.setValue(EPOCH, next);
        return next;
    }
    function same(a, b) { return (a == null) ? (b == null) : a.equals(b); }
    function contains(ids, id) {
        for (var i = 0; i < ids.size(); ++i) {
            if (ids[i].equals(id)) { return true; }
        }
        return false;
    }
    function rawList() {
        var ids = Application.Storage.getValue(INDEX);
        return (ids instanceof Lang.Array) ? ids : [];
    }

    // Exact credential comparison avoids assigning an old account's automatic
    // permissions to another account with coincident item IDs. Credentials are
    // already stored by login; this private snapshot is never shown/logged.
    // A changed server/token requires explicit re-enabling. Null/null is stable.
    function ensureScope() {
        var scope = Application.Storage.getValue(SCOPE);
        var server = AbsApi.serverUrl();
        var token = AbsApi.authToken();
        if ((scope != null) && same(scope["server"], server) && same(scope["token"], token)) {
            return scope["generation"];
        }
        var generation = cancelPending();
        // Invalidate subscriptions first. Cancel jobs before discarding their
        // authority, so an interrupted reset never turns automatic into manual.
        Application.Storage.deleteValue(INDEX);
        var jobs = JobStore.list();
        for (var i = 0; i < jobs.size(); ++i) {
            var oldOwner = Application.Storage.getValue(ownerKey(jobs[i]));
            var job = JobStore.get(jobs[i]);
            if ((oldOwner != null) || ((job != null) && (job["autoShow"] != null))) {
                cancelJob(jobs[i]);
            }
        }
        Application.Storage.setValue(SCOPE, {
            "server" => server, "token" => token, "generation" => generation
        });
        return generation;
    }
    function defaults(show, title) {
        return { "id" => show, "title" => title, "enabled" => false,
            "limit" => 1, "order" => "newest", "speed" => 100, "removeFinished" => false,
            "generation" => 0, "suppressed" => [] };
    }
    function get(show) {
        var scope = ensureScope();
        var config = Application.Storage.getValue(key(show));
        if ((config == null) || (config["scope"] != scope)) { return defaults(show, show); }
        return config;
    }
    function list() {
        ensureScope();
        var ids = rawList();
        var out = [];
        for (var i = 0; (i < ids.size()) && (out.size() < MAX_SHOWS); ++i) {
            if (get(ids[i])["enabled"] == true) { out.add(ids[i]); }
        }
        return out;
    }
    function matches(show, generation) {
        var config = get(show);
        return (config["enabled"] == true) && (config["generation"] == generation)
            && contains(list(), show);
    }
    function normalizedLimit(value) {
        if (!(value instanceof Lang.Number)) { return 1; }
        if (value < 1) { return 1; }
        return (value > 5) ? 5 : value;
    }
    function save(show, title, enabled, limit, order, removeFinished) {
        var scope = ensureScope();
        var ids = list();
        if (enabled && !contains(ids, show) && (ids.size() >= MAX_SHOWS)) { return false; }
        var previous = get(show);
        var suppressed = previous["suppressed"];
        if (suppressed == null) { suppressed = []; }
        // Re-enabling explicitly retries episodes previously removed/cleared.
        if (enabled && !previous["enabled"]) { suppressed = []; }
        if (!(title instanceof Lang.String)) { title = show; }
        if (title.length() > 160) { title = title.substring(0, 160); }
        var generation = cancelPending();
        var config = { "id" => show, "title" => title, "enabled" => enabled,
            "limit" => normalizedLimit(limit),
            "order" => same(order, "oldest") ? "oldest" : "newest",
            "removeFinished" => (removeFinished == true), "generation" => generation,
            "scope" => scope, "suppressed" => suppressed,
            "speed" => PlaybackSpeed.normalize(previous["speed"]) };
        // Value before index on enable; disabled value before job cancellation.
        Application.Storage.setValue(key(show), config);
        if (enabled) {
            if (!contains(ids, show)) { ids.add(show); }
        } else {
            var kept = [];
            for (var i = 0; i < ids.size(); ++i) {
                if (!ids[i].equals(show)) { kept.add(ids[i]); }
            }
            ids = kept;
            cancelAutomaticJobs(show);
        }
        Application.Storage.setValue(INDEX, ids);
        return true;
    }
    function setSpeed(show, title, speed) {
        var config = get(show);
        config["title"] = title;
        config["scope"] = ensureScope();
        config["speed"] = PlaybackSpeed.normalize(speed);
        config["generation"] = cancelPending();
        Application.Storage.setValue(key(show), config);
    }
    function cancelJob(itemId) {
        JobStore.remove(itemId);
        // Heal a saved-chunk/index crash window before orphan cleanup can run.
        if ((BookStore.get(itemId) != null) && (BookStore.count(itemId) > 0)) {
            BookStore.addToIndex(itemId);
        } else {
            BookStore.dropArtIfUnindexed(itemId);
            forget(itemId);
        }
    }
    function cancelAutomaticJobs(show) {
        var jobs = JobStore.list();
        for (var i = 0; i < jobs.size(); ++i) {
            var record = owner(jobs[i]);
            var job = JobStore.get(jobs[i]);
            if (((record != null) && record["show"].equals(show))
                || ((job != null) && same(job["autoShow"], show))) {
                cancelJob(jobs[i]);
            }
        }
    }
    function owner(itemId) {
        var scope = ensureScope();
        var record = Application.Storage.getValue(ownerKey(itemId));
        return ((record != null) && (record["scope"] == scope)) ? record : null;
    }
    function claim(itemId, show, generation) {
        if (!matches(show, generation)) { return false; }
        var old = owner(itemId);
        if ((old != null) && !old["show"].equals(show)) { return false; }
        // Ownership can never be retroactively applied to an existing manual
        // download/job, including content from builds predating this feature.
        if ((old == null) && ((JobStore.get(itemId) != null) || (BookStore.get(itemId) != null))) {
            return false;
        }
        Application.Storage.setValue(ownerKey(itemId), {
            "show" => show, "generation" => generation, "scope" => ensureScope()
        });
        return true;
    }
    // Internal cleanup after failed queueing or completed retention. No
    // permission changes and no epoch churn; a live job/audio keeps its owner.
    function forget(itemId) {
        if ((JobStore.get(itemId) == null) && (BookStore.totalChunks(itemId) == 0)) {
            Application.Storage.deleteValue(ownerKey(itemId));
        }
    }
    function release(itemId) {
        cancelPending();
        // Convert the pending job before deleting ownership. Bumping its gen
        // also invalidates an automatic chunk already in flight.
        var job = JobStore.get(itemId);
        if ((job != null) && (job["autoShow"] != null)) {
            job.remove("autoShow");
            job.remove("autoGeneration");
            job.remove("retryAt");
            // Use the persistent allocator: a local increment could collide
            // with a new job after Clear queue removes this adopted job.
            job["gen"] = JobStore.nextGeneration();
            JobStore.put(itemId, job);
        }
        Application.Storage.deleteValue(ownerKey(itemId));
    }
    // One pass can share this inventory across all ten shows. Do not rescan
    // the whole downloaded library for every candidate.
    function inventory() {
        var out = {};
        var ids = Application.Storage.getValue(Store.BOOK_INDEX);
        if (ids == null) { ids = []; }
        var jobs = JobStore.list();
        for (var i = 0; i < jobs.size(); ++i) {
            if (!contains(ids, jobs[i])) { ids.add(jobs[i]); }
        }
        var scope = ensureScope();
        for (var i = 0; i < ids.size(); ++i) {
            var record = Application.Storage.getValue(ownerKey(ids[i]));
            if ((record == null) || (record["scope"] != scope)) { continue; }
            var show = record["show"];
            if (out[show] == null) { out[show] = []; }
            out[show].add(ids[i]);
        }
        return out;
    }
    function owned(show) {
        var all = inventory();
        return (all[show] == null) ? [] : all[show];
    }
    function isSuppressed(itemId) {
        var shows = list();
        for (var i = 0; i < shows.size(); ++i) {
            var excluded = get(shows[i])["suppressed"];
            if ((excluded != null) && contains(excluded, itemId)) { return true; }
        }
        return false;
    }
    function suppress(itemId) {
        var record = owner(itemId);
        if (record == null) { return; }
        var config = get(record["show"]);
        var excluded = config["suppressed"];
        if (excluded == null) { excluded = []; }
        if (!contains(excluded, itemId)) {
            if (excluded.size() >= MAX_SUPPRESSED) {
                // No silent eviction of an exclusion: stop this show until
                // the user explicitly enables it again. Storage stays bounded.
                save(config["id"], config["title"], false, config["limit"],
                    config["order"], config["removeFinished"]);
            } else {
                excluded.add(itemId);
                config["suppressed"] = excluded;
                Application.Storage.setValue(key(record["show"]), config);
            }
        }
        release(itemId);
    }
    function adopt(itemId) {
        var shows = list();
        for (var i = 0; i < shows.size(); ++i) {
            var config = get(shows[i]);
            var excluded = config["suppressed"];
            if ((excluded == null) || !contains(excluded, itemId)) { continue; }
            var kept = [];
            for (var j = 0; j < excluded.size(); ++j) {
                if (!excluded[j].equals(itemId)) { kept.add(excluded[j]); }
            }
            config["suppressed"] = kept;
            Application.Storage.setValue(key(shows[i]), config);
        }
        release(itemId);
    }
}

// Settings are on the watch because subscriptions refer to live show IDs.
// Management remains reachable even before the first episode downloads.
module PodcastMenus {
    function showSettings(show, title) {
        WatchUi.pushView(new PodcastShowMenu(show, title),
            new PodcastShowDelegate(show, title), WatchUi.SLIDE_LEFT);
    }
    function manage() {
        var menu = new WatchUi.Menu2({ :title => WatchUi.loadResource(Rez.Strings.podcastDownloads) });
        var shows = PodcastSettings.list();
        for (var i = 0; i < shows.size(); ++i) {
            var config = PodcastSettings.get(shows[i]);
            menu.addItem(new WatchUi.MenuItem(config["title"], null, shows[i], null));
        }
        menu.addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.podcastAddShow),
            null, "__browse__", null));
        WatchUi.pushView(menu, new PodcastManageDelegate(), WatchUi.SLIDE_LEFT);
    }
    function enabledLabel(enabled) {
        return WatchUi.loadResource(enabled ? Rez.Strings.podcastOn : Rez.Strings.sleepOff);
    }
}
class PodcastManageDelegate extends WatchUi.Menu2InputDelegate {
    function initialize() { Menu2InputDelegate.initialize(); }
    function onSelect(item) {
        if (item.getId().equals("__browse__")) {
            WatchUi.pushView(new LibraryView(), new LibraryViewDelegate(), WatchUi.SLIDE_LEFT);
        } else { PodcastMenus.showSettings(item.getId(), item.getLabel()); }
    }
    function onBack() { WatchUi.popView(WatchUi.SLIDE_RIGHT); }
}
class PodcastShowMenu extends WatchUi.Menu2 {
    function initialize(show, title) {
        Menu2.initialize({ :title => title });
        var config = PodcastSettings.get(show);
        addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.podcastAutomatic),
            PodcastMenus.enabledLabel(config["enabled"]), "enabled", null));
        addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.podcastKeepLatest),
            config["limit"].toString(), "limit", null));
        addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.podcastOrder),
            WatchUi.loadResource(config["order"].equals("oldest") ? Rez.Strings.podcastOldest : Rez.Strings.podcastNewest), "order", null));
        addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.podcastDownloadSpeed),
            PlaybackSpeed.label(config["speed"]), "speed", null));
        addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.podcastRemoveFinished),
            PodcastMenus.enabledLabel(config["removeFinished"]), "remove", null));
    }
}
class PodcastShowDelegate extends WatchUi.Menu2InputDelegate {
    private var mShow;
    private var mTitle;
    function initialize(show, title) {
        Menu2InputDelegate.initialize(); mShow = show; mTitle = title;
    }
    function onSelect(item) {
        var key = item.getId();
        var config = PodcastSettings.get(mShow);
        if (key.equals("speed")) {
            var menu = new WatchUi.Menu2({ :title => WatchUi.loadResource(Rez.Strings.podcastDownloadSpeed) });
            for (var i = 0; i < PlaybackSpeed.ALL.size(); ++i) {
                var speed = PlaybackSpeed.ALL[i];
                menu.addItem(new WatchUi.MenuItem(PlaybackSpeed.label(speed), null, speed, null));
            }
            WatchUi.pushView(menu, new PodcastSpeedDelegate(mShow, mTitle, item), WatchUi.SLIDE_LEFT);
            return;
        }
        if (key.equals("limit")) {
            var menu = new WatchUi.Menu2({ :title => WatchUi.loadResource(Rez.Strings.podcastKeepLatest) });
            for (var i = 1; i <= 5; ++i) {
                menu.addItem(new WatchUi.MenuItem(i.toString(),
                    WatchUi.loadResource(Rez.Strings.podcastUnfinished), i, null));
            }
            WatchUi.pushView(menu, new PodcastLimitDelegate(mShow, mTitle, item), WatchUi.SLIDE_LEFT);
            return;
        }
        if (key.equals("enabled")) { config["enabled"] = !config["enabled"]; }
        else if (key.equals("order")) { config["order"] = config["order"].equals("newest") ? "oldest" : "newest"; }
        else if (key.equals("remove")) { config["removeFinished"] = !config["removeFinished"]; }
        if (!PodcastSettings.save(mShow, mTitle, config["enabled"], config["limit"], config["order"], config["removeFinished"])) {
            Notify.flash(Rez.Strings.podcastShowLimit); return;
        }
        if (key.equals("order")) {
            item.setSubLabel(WatchUi.loadResource(config["order"].equals("oldest") ? Rez.Strings.podcastOldest : Rez.Strings.podcastNewest));
        } else {
            item.setSubLabel(PodcastMenus.enabledLabel(key.equals("enabled") ? config["enabled"] : config["removeFinished"]));
        }
    }
    function onBack() { WatchUi.popView(WatchUi.SLIDE_RIGHT); }
}
class PodcastLimitDelegate extends WatchUi.Menu2InputDelegate {
    private var mShow;
    private var mTitle;
    private var mRow;
    function initialize(show, title, row) {
        Menu2InputDelegate.initialize(); mShow = show; mTitle = title; mRow = row;
    }
    function onSelect(item) {
        var config = PodcastSettings.get(mShow);
        if (PodcastSettings.save(mShow, mTitle, config["enabled"], item.getId(), config["order"], config["removeFinished"])) {
            mRow.setSubLabel(item.getId().toString());
        } else { Notify.flash(Rez.Strings.podcastShowLimit); }
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
    function onBack() { WatchUi.popView(WatchUi.SLIDE_RIGHT); }
}

class PodcastSpeedDelegate extends WatchUi.Menu2InputDelegate {
    private var mShow;
    private var mTitle;
    private var mRow;
    function initialize(show, title, row) {
        Menu2InputDelegate.initialize(); mShow = show; mTitle = title; mRow = row;
    }
    function onSelect(item) {
        PodcastSettings.setSpeed(mShow, mTitle, item.getId());
        mRow.setSubLabel(PlaybackSpeed.label(item.getId()));
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
    function onBack() { WatchUi.popView(WatchUi.SLIDE_RIGHT); }
}
