using Toybox.Application;
using Toybox.Test;
using Toybox.WatchUi;

// The optional reverse-proxy header (issue #41). What matters is that the
// header is attached to EVERY watch->sidecar request when configured and to
// none of them when it isn't - a single unguarded route would be rejected by
// the proxy and look like an unrelated intermittent fault.

(:test)
function proxyHeaderOffByDefault(logger) {
    Application.Storage.deleteValue(Store.PROXY_NAME);
    Application.Storage.deleteValue(Store.PROXY_VALUE);

    Test.assertMessage(!AbsApi.hasProxyHeader(), "unset means off");
    Test.assertMessage(AbsApi.proxyHeaders() == null, "nothing to send when off");

    // Requests must be byte-identical to before the feature existed: no
    // :headers key at all on a GET, and only Content-Type on a POST.
    Test.assertMessage(!AbsApi.getOptions().hasKey(:headers),
        "GET must not carry an empty headers dict when the feature is off");
    Test.assertMessage(!AbsApi.healthOptions().hasKey(:headers),
        "health preflight must not either");
    var post = AbsApi.postOptions()[:headers];
    Test.assertEqual(post.keys().size(), 1);
    Test.assertMessage(post.hasKey("Content-Type"), "POST keeps its Content-Type");

    logger.debug("unconfigured requests are unchanged by the feature");
    return true;
}

(:test)
function proxyHeaderRidesOnEveryRequestShape(logger) {
    ProxyHeader.save("X-Client-Authentication", "s3cr3t");
    Test.assertMessage(AbsApi.hasProxyHeader(), "both halves stored");

    // JSON GET (libraries/list/files/progress/...)
    var get = AbsApi.getOptions();
    Test.assertEqual(get[:headers]["X-Client-Authentication"], "s3cr3t");

    // text/plain GET - the /health preflight, the FIRST request a proxy sees.
    var health = AbsApi.healthOptions();
    Test.assertEqual(health[:headers]["X-Client-Authentication"], "s3cr3t");

    // POST (login/progress) must keep Content-Type AND gain the secret.
    var post = AbsApi.postOptions()[:headers];
    Test.assertEqual(post["X-Client-Authentication"], "s3cr3t");
    Test.assertMessage(post.hasKey("Content-Type"),
        "the proxy header must not displace Content-Type");

    ProxyHeader.save("", null);
    logger.debug("header rides on JSON GET, plain-text GET and POST alike");
    return true;
}

(:test)
function proxyHeaderNeedsBothHalves(logger) {
    // A name with no secret would advertise the scheme without satisfying it,
    // so it must count as OFF rather than send an empty value.
    Application.Storage.setValue(Store.PROXY_NAME, "X-Client-Authentication");
    Application.Storage.deleteValue(Store.PROXY_VALUE);
    Test.assertMessage(!AbsApi.hasProxyHeader(), "name alone is not enough");

    // An empty string is unset, not a value - Properties hand back "" for a
    // setting the user cleared in Garmin Connect.
    Application.Storage.setValue(Store.PROXY_VALUE, "");
    Test.assertMessage(!AbsApi.hasProxyHeader(), "empty secret is unset");

    Application.Storage.setValue(Store.PROXY_VALUE, "s3cr3t");
    Test.assertMessage(AbsApi.hasProxyHeader(), "both present means on");

    ProxyHeader.save("", null);
    return true;
}

(:test)
function proxyHeaderClearsBothHalves(logger) {
    ProxyHeader.save("X-Client-Authentication", "s3cr3t");
    Test.assertMessage(AbsApi.hasProxyHeader(), "configured");

    // Clearing by empty name must drop the SECRET too, so re-enabling later
    // cannot silently reuse a secret the user thought they had removed.
    ProxyHeader.save("", null);
    Test.assertMessage(!AbsApi.hasProxyHeader(), "cleared");
    Test.assertMessage(Application.Storage.getValue(Store.PROXY_VALUE) == null,
        "the secret must not survive a clear");
    Test.assertEqual(ProxyHeader.summary(),
        WatchUi.loadResource(Rez.Strings.proxyNotSet));

    logger.debug("clearing drops the secret, not just the name");
    return true;
}

// A version bump wipes Storage. Losing the proxy header there is a LOCKOUT:
// the user cannot reach the sidecar to re-enter it, and cannot re-enter it
// anywhere except on the watch. Pin the preserve-list that protects it.
(:test)
function proxyHeaderSurvivesVersionWipe(logger) {
    ProxyHeader.save("X-Client-Authentication", "s3cr3t");
    Application.Storage.setValue(Store.SERVER, "https://example.invalid");
    Application.Storage.setValue(Store.TOKEN, "tok");
    Application.Storage.setValue(Store.BOOK_INDEX, ["dummy"]);

    // Exactly what WatchShelfApp.initialize() does on a version change.
    var server = Application.Storage.getValue(Store.SERVER);
    var token = Application.Storage.getValue(Store.TOKEN);
    var pName = Application.Storage.getValue(Store.PROXY_NAME);
    var pValue = Application.Storage.getValue(Store.PROXY_VALUE);
    Application.Storage.clearValues();
    if (server != null) { Application.Storage.setValue(Store.SERVER, server); }
    if (token != null) { Application.Storage.setValue(Store.TOKEN, token); }
    if (pName != null) { Application.Storage.setValue(Store.PROXY_NAME, pName); }
    if (pValue != null) { Application.Storage.setValue(Store.PROXY_VALUE, pValue); }

    Test.assertMessage(AbsApi.hasProxyHeader(), "header survived the wipe");
    Test.assertEqual(AbsApi.getOptions()[:headers]["X-Client-Authentication"], "s3cr3t");
    Test.assertMessage(Application.Storage.getValue(Store.BOOK_INDEX) == null,
        "unrelated state was still wiped");

    ProxyHeader.save("", null);
    Application.Storage.deleteValue(Store.SERVER);
    Application.Storage.deleteValue(Store.TOKEN);
    logger.debug("proxy header survives the version-change wipe");
    return true;
}
