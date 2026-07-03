using Toybox.Communications;

// Injects a context object into a web-request callback. The wrapped callback
// always takes 3 args: (responseCode, data, context). Verbatim from MonkeyMusic.
class RequestDelegate {
    hidden var mCallback; // Method taking 3 arguments
    hidden var mContext;  // the 3rd argument to hand back

    function initialize(callback, context) {
        mCallback = callback;
        mContext = context;
    }

    function makeWebRequest(url, params, options) {
        Communications.makeWebRequest(url, params, options, self.method(:onWebResponse));
    }

    // Same context-injection, for image downloads (cover art). The callback
    // data is a WatchUi.BitmapResource (or null on error) instead of JSON.
    function makeImageRequest(url, params, options) {
        Communications.makeImageRequest(url, params, options, self.method(:onWebResponse));
    }

    function onWebResponse(code, data) {
        mCallback.invoke(code, data, mContext);
    }
}
