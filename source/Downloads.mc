using Toybox.Application;
using Toybox.Communications;

// Shared deletion path for downloaded books - used by the per-book action menu
// (one book) and the "Delete all downloads" confirmation (every book). Queue the
// whole books and kick a sync; SyncDelegate.deleteQueued evicts each cached
// chunk. Whole-book only: per-chunk state is what used to OOM-crash the app
// (see Constants.mc).
module Downloads {
    function queueDelete(itemIds) {
        if (itemIds.size() == 0) { return; }
        var deleteList = Application.Storage.getValue(Store.DELETE_LIST);
        if (deleteList == null) { deleteList = []; }
        for (var i = 0; i < itemIds.size(); ++i) {
            deleteList.add(itemIds[i]);
        }
        Application.Storage.setValue(Store.DELETE_LIST, deleteList);
        Communications.startSync();
        Notify.flash(Rez.Strings.deleting);
    }
}
