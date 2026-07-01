using Toybox.Graphics;
using Toybox.WatchUi;

// Centered single-message view used for errors and short confirmations.
class ErrorView extends WatchUi.View {

    private var mMessage;

    function initialize(message) {
        View.initialize();
        mMessage = message;
    }

    function onUpdate(dc) {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.drawText(dc.getWidth() / 2, dc.getHeight() / 2, Graphics.FONT_SMALL,
            mMessage, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }
}
