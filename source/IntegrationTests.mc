using Toybox.Application;
using Toybox.Test;
using Toybox.WatchUi;

// Tests that exercise the REAL views and the REAL Storage layout on the
// Connect IQ simulator, rather than pure helper functions. They exist because
// the simulator has no scripted UI driver - monkeydo only runs code - so this
// is how the fixed flows get executed on an emulated device at all.
//
// Everything is created and torn down inside each test; nothing is left in
// Storage for the next one.

// ---------------------------------------------------------------------------
// #44 / #50: a long book used to trip the watchdog while building the playlist.
// buildPlaylist() was O(chunks^2) AND walked the whole OS audio cache. This
// synthesises a book at the scale that was reported failing (a ~20h single-file
// book, several hundred parts) and builds a real ContentIterator over it.
// ---------------------------------------------------------------------------
(:test)
function longBookPlaylistBuilds(logger) {
    var item = "__watchshelf_longbook__";
    var durs = [72000];                       // 20 hours in one file
    var total = Chunks.total(durs);
    Test.assertMessage(total > 350, "fixture must be a genuinely long book, got " + total);

    // Lay the book down exactly as SyncDelegate would: metadata, then refIds
    // paged at PAGE_SIZE, then the index entry.
    Application.Storage.setValue("trk:" + item,
        { "title" => "Long Book", "author" => "Tester", "durs" => durs,
          "first" => 0, "speed" => 100 });
    var page = [];
    var p = 0;
    for (var k = 0; k < total; ++k) {
        page.add("ref" + k.toString());
        if (page.size() == 256) {
            Application.Storage.setValue("trkc:" + item + ":" + p, page);
            page = []; p += 1;
        }
    }
    if (page.size() > 0) { Application.Storage.setValue("trkc:" + item + ":" + p, page); }
    Application.Storage.setValue(Store.BOOK_INDEX, [item]);

    // The call that used to be killed by the watchdog.
    var it = new ContentIterator({ "item" => item, "mode" => "start" });

    Test.assertEqual(it.size(), total);
    // Order is what the removed sort used to guarantee; it now comes from the
    // page/slot layout, so prove it really is ascending by book position.
    Test.assertEqual(it.startAt(0), 0);
    Test.assertEqual(it.startAt(1), Chunks.FIRST);
    Test.assertMessage(it.startAt(total - 1) > it.startAt(total - 2), "ends ascending");
    var starts = Chunks.starts(durs);
    Test.assertEqual(it.startAt(total - 1), starts[total - 1]);
    Test.assertEqual(it.globalAt(total - 1), total - 1);

    // Clean up every key this test wrote.
    for (var q = 0; q <= p; ++q) { Application.Storage.deleteValue("trkc:" + item + ":" + q); }
    Application.Storage.deleteValue("trk:" + item);
    Application.Storage.deleteValue(Store.BOOK_INDEX);

    logger.debug("built a " + total + "-part playlist in order, no watchdog");
    return true;
}

// ---------------------------------------------------------------------------
// #48: the login state machine, driven the way the keyboard drives it. On a
// device without WatchUi.TextPicker this is the path that used to die before a
// single character could be typed.
// ---------------------------------------------------------------------------
(:test)
function loginFlowCollectsAllThreeFields(logger) {
    var view = new LoginView();

    // Field 0 is seeded with the saved server URL (or https://), 1 and 2 are
    // collected fresh. setField is exactly what both keyboards call back into.
    view.setField(0, "https://shelf.example.com");
    view.setField(1, "tester");
    view.setField(2, "hunter2");

    // State 3 is "all fields in hand, submit" - reaching it means the flow
    // advanced through every field rather than stalling on one.
    Test.assertEqual(view.state(), 3);
    Test.assertEqual(view.creds().server, "https://shelf.example.com");
    Test.assertEqual(view.creds().username, "tester");
    Test.assertEqual(view.creds().password, "hunter2");

    // Cancelling from any field parks the flow instead of submitting.
    var v2 = new LoginView();
    v2.setField(0, "https://shelf.example.com");
    v2.cancelFlow();
    Test.assertEqual(v2.state(), 99);

    logger.debug("login collects server/user/password and honours cancel");
    return true;
}

// ---------------------------------------------------------------------------
// #57: the proxy-header collector, driven end to end, including the "empty
// name clears everything" gesture.
// ---------------------------------------------------------------------------
(:test)
function proxyHeaderFlowStoresAndClears(logger) {
    Application.Storage.deleteValue(Store.PROXY_NAME);
    Application.Storage.deleteValue(Store.PROXY_VALUE);

    var view = new ProxyHeaderView(null);
    view.setField(0, "X-Client-Authentication");
    Test.assertEqual(view.state(), 1);          // advanced to the secret
    view.setField(1, "s3cr3t");
    Test.assertEqual(view.state(), 2);          // ready to save
    ProxyHeader.save(view.name(), view.value());

    Test.assertMessage(AbsApi.hasProxyHeader(), "header is configured");
    Test.assertEqual(AbsApi.getOptions()[:headers]["X-Client-Authentication"], "s3cr3t");

    // An empty NAME must skip the secret prompt entirely and clear both halves.
    var v2 = new ProxyHeaderView(null);
    v2.setField(0, "");
    Test.assertEqual(v2.state(), 2);            // jumped past the secret
    ProxyHeader.save(v2.name(), v2.value());
    Test.assertMessage(!AbsApi.hasProxyHeader(), "cleared");
    Test.assertMessage(Application.Storage.getValue(Store.PROXY_VALUE) == null,
        "the secret must not survive");

    logger.debug("proxy header collected, applied to requests, and cleared");
    return true;
}

// ---------------------------------------------------------------------------
// #51: a book's recorded speed decides whether selecting a speed re-downloads
// it, and the compressed->source mapping is what keeps ABS progress honest.
// ---------------------------------------------------------------------------
(:test)
function playbackSpeedRoundTrips(logger) {
    var item = "__watchshelf_speed__";
    Application.Storage.deleteValue("trk:" + item);

    BookStore.ensureMeta(item, "Speedy", "Tester", [3600], 0, 150);
    Test.assertEqual(BookStore.get(item)["speed"], 150);

    // A book recorded before b37 has no speed key and must read as 1.0x, so
    // its existing 1.0x chunks are not needlessly re-downloaded.
    Application.Storage.setValue("trk:" + item,
        { "title" => "Old", "author" => "T", "durs" => [3600], "first" => 0 });
    Test.assertEqual(PlaybackSpeed.normalize(BookStore.get(item)["speed"]), 100);

    // 60s of compressed audio at 1.5x is 90s of the ABS source timeline.
    Test.assertEqual(PlaybackSpeed.sourceSeconds(60, 150), 90);
    Test.assertEqual(PlaybackSpeed.sourceSeconds(60, 100), 60);

    Application.Storage.deleteValue("trk:" + item);
    logger.debug("speed persists, defaults to 1.0x on legacy books, maps to source");
    return true;
}
