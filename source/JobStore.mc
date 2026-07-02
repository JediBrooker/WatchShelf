using Toybox.Application;

// Persistent store for QUEUED download jobs - one job per Storage key, plus a
// small index, mirroring BookStore's layout:
//
//   "jobidx"        => [ itemId, ... ]
//   "job:" + itemId => { "inos" => [str], "durs" => [num], "title" => str,
//                        "done" => num }
//
// One-job-per-key matters for the same reason BookStore pages do: a
// chapterized book can be hundreds of per-chapter files, so a job's
// inos+durs arrays are O(files) (~15KB at 700 files). Several such books in
// ONE value would cross the documented 32KB-per-value cap - the same crash
// class the b26 redesign eliminated for chunks (see Constants.mc).
//
// Crash-window discipline: put() writes the value BEFORE the index entry,
// remove() drops the index entry BEFORE the value - an interruption can only
// leave an unindexed (invisible, overwritten-on-retry) value, never an index
// entry pointing at data mid-delete. A stray index entry with no value is
// self-healed by callers treating get()==null as "remove and move on".
module JobStore {

    const INDEX = "jobidx";

    // A job's inos+durs arrays are O(files) inside ONE Storage value; past
    // this many files the value approaches the 32KB cap (ABS inode strings
    // can be 19-20 digits on 64-bit filesystems: ~33B/file serialized ->
    // 600 files ~= 20KB, comfortable margin). BookMenuDelegate rejects
    // bigger books at queue time.
    const MAX_FILES = 600;

    function key(itemId) {
        return "job:" + itemId;
    }

    // Fresh copy of the queued itemIds ([] if none). Read fresh at every use -
    // never hold across events (see the lost-update post-mortem in
    // Constants.mc).
    function list() {
        var index = Application.Storage.getValue(INDEX);
        return (index == null) ? [] : index;
    }

    function get(itemId) {
        return Application.Storage.getValue(key(itemId));
    }

    function put(itemId, job) {
        Application.Storage.setValue(key(itemId), job);
        var index = list();
        for (var i = 0; i < index.size(); ++i) {
            if (index[i].equals(itemId)) { return; }
        }
        index.add(itemId);
        Application.Storage.setValue(INDEX, index);
    }

    function remove(itemId) {
        var index = list();
        var out = [];
        for (var i = 0; i < index.size(); ++i) {
            if (!index[i].equals(itemId)) { out.add(index[i]); }
        }
        if (out.size() > 0) {
            Application.Storage.setValue(INDEX, out);
        } else {
            Application.Storage.deleteValue(INDEX);
        }
        Application.Storage.deleteValue(key(itemId));
    }

    // Clear via per-entry remove() so every intermediate state keeps the
    // index-before-value discipline: a crash mid-clear leaves a valid,
    // smaller queue - never an index full of entries whose values are gone
    // (which would make isSyncNeeded() true forever with nothing to heal it).
    function clearAll() {
        var index = list();
        for (var i = 0; i < index.size(); ++i) {
            remove(index[i]);
        }
    }
}
