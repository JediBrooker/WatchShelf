// Integer percentages shared by the watch and sidecar.
module PlaybackSpeed {
    const NORMAL = 100;

    function normalize(value) {
        if ((value == 125) || (value == 150) || (value == 175) || (value == 200)) {
            return value;
        }
        return NORMAL;
    }

    // The five offered speeds, and their labels. One list so the picker and
    // normalize() can never disagree about what is selectable.
    const ALL = [ 100, 125, 150, 175, 200 ];
    function label(value) {
        var v = normalize(value);
        if (v == 125) { return "1.25x"; }
        if (v == 150) { return "1.5x"; }
        if (v == 175) { return "1.75x"; }
        if (v == 200) { return "2.0x"; }
        return "1.0x";
    }

    // Map seconds on the compressed output back to the source timeline.
    function sourceSeconds(outputSeconds, speed) {
        return ((((outputSeconds * normalize(speed)) + 50) / 100).toNumber());
    }
}
