// Integer percentages shared by the watch and sidecar.
module PlaybackSpeed {
    const NORMAL = 100;

    function normalize(value) {
        if ((value == 125) || (value == 150) || (value == 175) || (value == 200)) {
            return value;
        }
        return NORMAL;
    }

    // Map seconds on the compressed output back to the source timeline.
    function sourceSeconds(outputSeconds, speed) {
        return ((((outputSeconds * normalize(speed)) + 50) / 100).toNumber());
    }
}
