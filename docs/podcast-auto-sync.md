# Automatic podcast downloads

Implemented in source build **b42** for [issue #85](https://github.com/JediBrooker/WatchShelf/issues/85).
Update the watch and sidecar together. Source availability does not mean the
matching package has been published in the Connect IQ Store.

## Set up on the watch

Open **Downloaded → Browse library → a podcast library → Shows → a show →
Automatic downloads**. Automatic downloads and finished-episode removal both
start **Off**. Choose:

- **Automatic downloads:** enable this show, with at most 10 enabled shows.
- **Keep latest unfinished:** 1–5 episodes, including partially heard episodes.
- **Download order:** newest first (default), or oldest first within the latest-N
  eligible episodes.
- **Download speed:** 1.0x (default), 1.25x, 1.5x, 1.75x or 2.0x. This applies to
  new automatic additions; it does not replace an existing unfinished download.
- **Remove finished downloads:** optionally remove completed automatic episodes
  after their listening progress is confirmed by the server.

**Downloaded → Podcast downloads** manages enabled shows and provides **Add a
show**, including when nothing has downloaded yet. **Sync now** is available on a
configured watch even with an empty downloaded library.

Episodes must already have audio in Audiobookshelf. Configure ABS feed fetching
separately; WatchShelf does not make ABS download missing episodes.

## What is kept

N is the maximum number of **unfinished automatic** downloads for one show,
including queued and incomplete jobs. Existing unfinished downloads stay when
newer episodes arrive. Only vacancies are filled from the latest-N candidate set;
WatchShelf does not reach further into a show's backlog to replace an excluded
candidate. Lowering N pauses additions until the count is below N. A completed
episode retained on the watch does not count toward N, but its audio still uses
the watch-wide storage budget.

Turning a show off cancels its pending automatic jobs and stops discovery. Audio
already downloaded stays playable. Manually downloading an episode, changing its
speed through the ordinary download flow, or choosing **Keep on watch** removes
its automatic ownership. Finished-episode removal can no longer delete it.
Downloads from older builds are manual by default.

Deleting an automatic episode or clearing its queued download excludes that
episode from automatic rediscovery. Exclusions are bounded to 20 per show. If
another exclusion would exceed that cap, that show is turned off instead of
forgetting an exclusion. Explicitly turning the show on again clears its
exclusions; manually choosing an excluded episode also permits that episode.

Subscriptions are scoped to the configured server and login/API-key credential.
Changing either cancels automatic jobs and requires explicitly enabling shows
again. Downloaded audio stays; its old automatic ownership cannot authorize
removal under the new account. Sidecar-internal ABS access-token refresh does not
change the watch's session credential.

## Garmin lifecycle and timing

Automatic discovery and automatic job resumes require the watch to report that
it is connected to power, including at full battery. **Sync now** explicitly
allows automatic work without that charging gate and bypasses the discovery
cooldown for that run. It still respects a failed audio job's retry delay.
Ordinary manually selected downloads retain their existing flow; manual work
does not implicitly allow automatic work while unplugged.
Charging is checked again when discovery, file-metadata and automatic audio
callbacks arrive. Unplugging pauses automatic work and discards audio that was
still in flight, preserving the committed resume cursor.

The watch requests a check no more often than every six hours after successful
discovery, or one hour after a failed/interrupted attempt. Attempt and success
timestamps are separate; the retry deadline is stored before the first request.
Empty successful results count as fresh. Implausible future deadlines after clock
changes are clamped by the due check. Failed automatic audio jobs use a one-hour
retry delay and retain their resume cursor. A persisted show cursor shares work
across interrupted passes.

Garmin firmware decides when to poll `isSyncNeeded()` and establish connectivity.
No always-running timer or additional background service is installed. There is
**no exact overnight schedule guarantee**. Physical Venu 4 charging, full-battery,
phone-absent and Wi-Fi behavior still requires device validation; simulator tests
cannot establish those firmware behaviors. This feature does not resolve the
separate native Wi-Fi stall reported in issue #78.

## Sidecar contract and failure limits

`GET /podcasts/candidates?show=SHOW_ID&limit=1..5&order=newest|oldest&token=TOKEN`
is authenticated through the existing session/API-key path. The sidecar checks
access to the show and requires a podcast item. It filters unavailable audio and
finished episodes before selecting the latest N. Started episodes remain eligible.
Publication order uses episode ID as a deterministic tie breaker.

A successful response has `version: 1`, `checkedAtSec`, a small `show` object and
at most five `episodes`. Each episode contains its existing composite `id`,
`title`, `author`, publication time in seconds, and slim progress (or null).
Titles/authors are limited to 160 UTF-8 bytes and the complete response to 8 KiB.
The watch requests each episode's file metadata separately through `/files`.

Each discovery request allows at most 32 upstream requests including refreshes,
12 seconds total, a 1 MiB show response, 2 MiB total upstream response bytes, and
2,000 source episodes. Redirects do not bypass the request budget. Malformed,
oversized or budget-exhausting upstream results fail the check; they never return
an incomplete successful candidate set. A show with many finished newest episodes
may exceed the request budget and remain available for manual downloading.

Library responses retain the old `mediaType: "book"` compatibility shape and add
`sourceMediaType: "podcast"`; podcast author/show rows add `podcast: true`. Older
watches continue to browse the same responses. An older sidecar's missing route
(404) shows **Update sidecar** under Podcast downloads; ordinary downloads continue.
Missing/inaccessible shows on the new route do not masquerade as that 404.

## State, cancellation and progress safety

`PodcastSettings` stores a bounded enabled-show index, small per-show settings,
and separate per-episode ownership. `PodcastSync` processes one request and one
show response at a time, at most 10 shows and 50 candidate rows per pass. The
existing `Downloads.queue` validation is shared by manual and automatic work:
duration, resume, playback speed, file count, chunk budget and job generations
follow the same rules. `Chunks.MAX_TOTAL` remains 1,500 and `JobStore.MAX_FILES`
remains 600. The chunk limit counts the retained download suffix, queued work and
parked speed variants; it does not reject a long source book whose remaining tail
fits. Chunk calculations do not allocate the whole source book's chunk list.

Automatic additions also require the combined set of downloaded and queued item
IDs, including manual downloads, to fit a conservative 24 KiB serialized-size
estimate. This leaves margin below Storage's 32 KiB per-value ceiling when many
short episodes with long IDs accumulate. At this limit, automatic additions stop
before claiming ownership or creating a job; remove unwanted downloads or clear
jobs to make room. Existing audio and unfinished jobs are retained. This extra
index guard applies to automatic additions; manual downloads keep their existing
capacity behavior.

Before persisting a job, the shared queue bounds titles/authors to 180 characters
and file identifiers to 24 printable ASCII characters. File and aggregate duration
must be nonnegative finite numbers no greater than 1,000,000,000 seconds; progress
positions use the same ceiling and epoch seconds must fit a signed 32-bit value.
These checks bound the serialized 600-file job as well as arithmetic. Sync does
not request cover images.

Settings generations and a cancellation epoch invalidate stale discovery/file
callbacks. Download callbacks also check the fresh job generation, automatic
ownership and charging permission. Disabling a show, clearing jobs, manually
adopting an episode, changing credentials, or stopping sync cannot resurrect old
work. Ownership cleanup after failed additions or completed retention does not
leave an accumulating history of episode tombstones.

Ordinary queued work runs first. Progress exchange then returns acknowledgments
for individual episodes. Discovery must succeed before finished episodes are
considered for removal. Immediately before deleting audio, retention checks:

- current automatic ownership and enabled settings with removal still selected;
- no queued job or explicit exclusion;
- the exact finished progress acknowledged in this run, with no dirty local edit.

A failed pull/push, newer local listen or rewind, manual adoption, or setting
change prevents automatic deletion. A single persistent deletion journal keeps
the acknowledgment/progress record through an interrupted removal. Progress is
removed only after audio deletion and only if the exact acknowledged clean entry
still matches. Ordinary sync also checks an interrupted journal: if ownership,
settings or progress no longer permit removal, any surviving audio is made visible
again, even while unplugged or after the final show is disabled. Completing a
still-authorized removal requires fresh progress acknowledgment and a successful
discovery. Explicit user deletions keep their existing behavior.

## Validation

Watch tests cover settings bounds, account isolation, manual adoption, scheduling,
cancellation, queue limits, malformed responses, and retention acknowledgments.
Sidecar tests cover authorization, available/started/finished episodes, ordering,
budgets, malformed upstream responses, session refresh and legacy compatibility.
Commands, results and resource measurements are recorded in the
[b42 validation report](podcast-auto-sync-validation.md).

Physical validation is still required on Venu 4 45 mm: new episodes while idle,
charging at full battery, phone absent, Wi-Fi unavailable/reconnected,
unplugging/cancelling mid-sync, repeated firmware polls, and overnight retries.
