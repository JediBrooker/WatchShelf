# Proposal: automatic podcast sync

Status: proposed, not implemented. Tracks [issue #85](https://github.com/JediBrooker/WatchShelf/issues/85).

WatchShelf already participates in Garmin's system sync lifecycle, but currently
only requests a sync for queued downloads/deletes, dirty listening progress, or
the explicit **Sync now** action (`source/SyncDelegate.mc`). It does not discover
new episodes automatically. Podcast support currently lives in the sidecar:
shows appear as authors and episodes as books (`sidecar/server.js`). This feature
therefore needs coordinated watch and sidecar changes, not an unconditional
`return true` in `isSyncNeeded()`.

## Proposed behavior

- Add **Automatic downloads** to a podcast show's menu, off by default. Additive
  sidecar metadata must identify podcast libraries/shows without breaking older
  watches that use the existing book/author compatibility responses.
- Per show, allow **Keep latest 1–5 unfinished episodes**, a download order
  (**newest first**, default, or **oldest first** within that latest-N set), and
  **Remove finished automatic downloads**, off by default. “Unfinished” includes
  partially heard episodes; this wording avoids treating a started episode as
  ineligible. Start with at most 10 enabled shows.
- Download only episodes whose audio already exists in Audiobookshelf. Configuring
  ABS to fetch podcast feeds remains separate. Reuse the existing download speed
  selection, resumable jobs, chunk budget, and playback/progress behavior.
- Enforce N as the maximum number of unfinished automatic downloads per show,
  including queued/incomplete jobs. Keep existing unfinished downloads when the
  target set changes; only fill vacancies from the latest-N candidate set. Lowering
  N pauses additions until the count falls below N. This first version never
  discards an unfinished episode merely because a newer one appears.
- Turning the feature off stops discovery and cancels only its pending automatic
  jobs; already downloaded audio stays. Manually downloading an episode or choosing
  **Keep on watch** removes its automatic ownership, so retention cannot delete it.

## Garmin lifecycle and scheduling

[`Communications.SyncDelegate`](https://developer.garmin.com/connect-iq/api-docs/Toybox/Communications/SyncDelegate.html)
provides a synchronous `isSyncNeeded()` decision and an `onStartSync()` callback
for network work. Keep `isSyncNeeded()` local and inexpensive: preserve existing
manual-work/progress reasons to sync, then consider enabled subscriptions and a
persisted next-check time. Fetch episode availability only after `onStartSync()`.

For an automatically due podcast check, require
[`System.Stats.charging`](https://developer.garmin.com/connect-iq/api-docs/Toybox/System/Stats.html)
(available since API 3.0; true while connected to power even at full charge).
Apply that charging gate to resuming automatic jobs too; an unrelated manual sync
must not bypass it unless the user explicitly chose **Sync now**. Manual downloads
and **Sync now** retain their existing behavior. The firmware
decides when to invoke the delegate and establish Wi-Fi; returning true requests
work when polled and does not schedule an exact overnight start. Physical Venu 4
testing must confirm the charging trigger before promising unattended delivery.
Do not add an always-running timer or a separate background service to emulate it.

Suggested initial policy: check no more often than every six hours after success;
retry failed discovery after one hour. Persist an attempt/cooldown before the
first request so a crash cannot produce a rapid retry loop. Keep successful-check
and attempt timestamps distinct; empty successful results count as fresh, while
errors never authorize pruning. Clamp implausible timestamps after clock changes.
Explicit **Sync now** may bypass discovery cooldown once. A 404 from an older
sidecar disables discovery for that attempt and shows **Update sidecar**, while
ordinary downloads continue.

## Bounded sidecar contract

Add an authenticated `GET /podcasts/candidates` endpoint with validated `show`,
`limit` (1–5), and `order` parameters. Verify the session can access the show and
that the item is a podcast. Filter finished and unavailable episodes before
selecting the latest N; sort that selected set for the requested download order.

Return at most five small rows containing the existing composite episode ID,
bounded title/author strings, publication time, and slim progress metadata, plus
a response version and check timestamp. Obtain file metadata through the existing
`/files` route one episode at a time. Never send full show objects, episode arrays,
or the user's entire progress history to the watch. Bound upstream request count
and elapsed time as well as response bytes; reject oversized/malformed results
without altering watch state. Reuse session refresh, proxy-header behavior, and
upstream timeout handling.

Use one request at a time and one show's response at a time on the watch. Share
the existing queue-validation logic through a small non-UI component so automatic
jobs get the same duration, resume, storage, and generation checks as manual jobs.
Mark ownership in separate small per-episode records and a bounded subscription
index. Existing jobs/downloads without ownership metadata are manual. A settings
generation captured before a request must be rechecked before applying its result,
so disabling or editing a subscription cannot be undone by an old callback.

## Progress and retention safety

The current delete path removes `Progress` before the final `ProgressSync`; do
not reuse it unchanged for automatic pruning. Introduce a separate retention
phase, after ordinary queued work, whose order is:

1. Pull current server progress and apply the existing conflict policy; push any
   surviving local dirty progress. Return per-episode success/failure information
   from the exchange rather than treating its continuation as proof of success.
2. Discover candidates and plan additions. A local finished episode must not be
   downloaded again while its completion is waiting to be acknowledged remotely.
3. Prune only explicitly automatic-owned episodes with a confirmed finished
   state and no unacknowledged local progress. Re-read ownership, progress, job,
   and settings generation immediately before deletion. A failed request, newer
   local listen/rewind, manual adoption, or concurrent setting change skips pruning.
4. Queue eligible additions within remaining per-show and global chunk limits,
   download serially, then finish the normal progress exchange and system sync.

Retain enough progress/acknowledgment state to survive a crash during deletion.
Never erase a dirty progress entry to make room. Keep manual deletions governed by
the existing explicit user action; automatic retention must not broaden that
permission to manually downloaded books or episodes. A retained finished episode
does not count toward N unfinished episodes, but it still consumes the global
chunk budget and can prevent new downloads.

## Resource and failure limits

Keep `Chunks.MAX_TOTAL` (currently 1,500) and `JobStore.MAX_FILES` (600) authoritative;
automatic work cannot bypass capacity checks. Preserve per-book storage and avoid
per-chunk dictionaries in a single value. The existing code documents a 512 KB
audio-provider heap and 32 KB per-value storage limit; measure on both old and new
device profiles before selecting final caps.

Each callback must do bounded work and continue through asynchronous requests,
rather than walk an entire library or recursively drain arbitrary jobs. Limit a
discovery pass to 10 shows and 50 candidate rows in total, with a persisted cursor
and cooldown for partial passes. Use request timeouts, cancellation/run tokens,
and exactly one `notifySyncComplete()` per run. Cancelled/stale callbacks must not
restart downloads or prune content. Existing manual jobs continue if discovery
fails. Apply backoff to failed automatic jobs rather than requeueing them on
every system poll. Avoid cover-image requests in sync; the existing phoneless
audio-download path deliberately excludes them.

## Staged delivery and validation

1. Add sidecar metadata and candidate endpoint with tests for authorization,
   missing audio, started/finished states, deterministic ordering, request/byte
   limits, expiry/refresh, malformed upstream data, and old-client compatibility.
2. Add opt-in settings and persistent ownership, then discovery-only diagnostics.
   Test due/cooldown/clock behavior, old-sidecar fallback, cancellation, settings
   changes during requests, and interrupted storage writes. Do not delete audio.
3. Integrate automatic queueing with shared validation. Exercise duplicate manual
   and automatic requests, interrupted/resumed downloads, capacity limits, API
   failures, and disabled subscriptions. Run the relevant Monkey C simulator
   tests/builds for Forerunner 645 Music and Venu 4 45 mm.
4. Add opt-in retention only after progress acknowledgments are observable. Test
   dirty offline completion, failed pushes/pulls, concurrent rewinds, manual
   adoption, crash/restart during deletion, and missing ownership metadata.
5. Validate on physical Venu 4 45 mm with the issue reporter: new episode while
   idle, charging at full battery, phone absent, Wi-Fi absent/reconnected,
   unplugging/cancelling mid-sync, repeated firmware polls, and overnight retries.
   Simulator success cannot establish native Wi-Fi or charging behavior.

Ship automatic downloading before optional retention if device testing reveals
uncertainty. Keep this proposal separate from [issue #78](https://github.com/JediBrooker/WatchShelf/issues/78),
which reports a native Wi-Fi connection stall and needs device diagnostics.
