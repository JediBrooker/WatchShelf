# b42 podcast auto-sync validation

Recorded on 28 October 2026 for the implementation of
[issue #85](https://github.com/JediBrooker/WatchShelf/issues/85). This source build
has not been published to the Connect IQ Store. The behavior and capacity limits
are documented in [automatic podcast downloads](podcast-auto-sync.md).

The sidecar suite, both watch suites, resource probes and release builds below
passed against the final source, including the automatic-index capacity guard.

## Confirmed checks

| Check | Command or fixture | Result |
|---|---|---|
| Sidecar regression and integration suite | `npm test --prefix sidecar` | 32 passed, 0 failed |
| Watch suite, Forerunner 645 Music (`fr645m`) | `monkeyc -t`; `monkeydo ... fr645m -t` | 73 passed, 0 failed, 0 errors |
| Watch suite, Venu 4 45 mm (`venu445mm`) | `monkeyc -t`; `monkeydo ... venu445mm -t` | 73 passed, 0 failed, 0 errors |
| Signed device builds | `make build DEVICE=fenix847mm BIN=bin/b42-fenix847mm`; same for `venu445mm` | Both passed, process status 0, no warnings |
| Store package | `make package` | 151/151 eligible firmware variants across 93 device targets; process status 0 |

The final sidecar suite completed with process status 0 on Node.js 24.15.0; its
local output is `/tmp/watchshelf-b42-sidecar-tests.log`.

The sidecar suite includes the existing API-key/session, podcast playback and
transcoding behavior, plus candidate access control, unfinished filtering,
deterministic selection and order, byte/request/time budgets, malformed upstream
data, numeric bounds, token refresh and legacy metadata compatibility. Discovery
tests use a controlled ABS fixture; they are not a live-server overnight trial.

The watch suite includes the 45 existing tests and 28 new tests covering settings
bounds, account isolation, manual adoption, cooldowns, automatic/manual charging
rules, late callbacks, cancellation, retry cursors, numeric and index capacity
limits, long-book tail downloads, exact progress acknowledgments and interrupted
retention recovery. Request harnesses drive the real asynchronous handlers.
The compile and test logs are `/tmp/watchshelf-b42-{fr645m,venu445mm}-{compile,tests}.log`.

In an isolated Venu 4 simulator fixture, **Downloaded → Podcast downloads →
Example Podcast → Keep latest unfinished** rendered using the native menus.
Selecting 2 updated the displayed stored count from 3 to 2. This visual check
covered the menu and count flow; it did not exercise every speed or removal
toggle.

## Release artifacts

The final package compiled all eligible targets. Its warnings were launcher-icon
scaling and exclusion of one D2 Delta PX firmware variant on API 3.0.3, below the
app's 3.1.0 minimum. The final single-device builds had no warnings. The source
and resource hash snapshot remained unchanged throughout the builds.

| Artifact | Bytes | SHA-256 |
|---|---:|---|
| `bin/b42-fenix847mm/WatchShelf.prg` | 239,116 | `d41d3e53cc326ba662ddb3747cfb9706e8b5f6387f3dcc622056d320b0c53f50` |
| `bin/b42-venu445mm/WatchShelf.prg` | 239,116 | `798451bd7199f6789d53f5129f117f313c9c441bf253290b1b64c1be589a304c` |
| `bin/WatchShelf.iq` | 9,328,165 | `933f4a258c55a3711318c244f3aeeee00d4849b9effccdf512a8b73482c8fe50` |

Exact symbols are archived as `debug-symbols/b42-fenix847mm.debug.xml` and
`debug-symbols/b42-venu445mm.debug.xml`; both match their corresponding build
outputs byte-for-byte. Build evidence is in
`/tmp/watchshelf-b42-{fenix847mm-build,venu445mm-build,package}.log`, with sizes and
hashes in `/tmp/watchshelf-b42-release-artifacts.json`. These successful builds do
not establish Connect IQ Store publication or physical-watch behavior.

## Resource probes

The Connect IQ SDK 9.2.0 simulator reported a 519,880-byte heap on both profiles.
A temporary harness exercised accepted limits using the real queue, settings,
discovery and playback code. All six probes passed.

| Probe | Profile | Elapsed | Sampled memory |
|---|---|---|---|
| Queue 600 files with identifiers up to 24 printable ASCII characters | `fr645m` | 39 ms | 301,944 bytes before, 302,272 after |
| Same 600-file queue | `venu445mm` | 31 ms | 275,976 bytes before, 276,312 after |
| Discover 10 shows and queue 50 episodes | `fr645m` | 2,739 ms | Maximum post-callback sample: 160,488 bytes |
| Same 10-show discovery | `venu445mm` | 2,731 ms | Maximum post-callback sample: 134,520 bytes |
| Build playback iterator and lookup for 1,500 chunks across 600 files | `fr645m` | 5,055 ms | 165,216 bytes before, 451,640 after |
| Same 1,500-chunk playback structures | `venu445mm` | 4,651 ms | 139,248 bytes before, 425,680 after |

The 600-file cases persisted jobs without exceptions; this verifies storage-write
acceptance, not an exact serialized byte count. Both discovery cases made 60
mocked requests, queued 50 jobs and completed once. Both playback cases built
an iterator and lookup with 1,500 entries each.

These are simulator samples, not transient peak-memory measurements or physical
watch timings. The discovery probe responds synchronously to mocked requests;
its elapsed time does not estimate actual network or audio-download duration.
The playback probe uses stored reference identifiers and does not play audio.

Local probe evidence is retained under `/tmp/watchshelf-podcast-resource/`:
`ResourceStressTests.mc`, `resource.jungle`, and
`podcastResource{600Files,TenShowsFiftyCandidates,1500Chunks}-{fr645m,venu445mm}.log`.
The temporary harness leaves the repository's production source and test list
unchanged. Source hashes were recorded in
`/tmp/watchshelf-b42-verified-sources.sha256` and all checked successfully in
`/tmp/watchshelf-b42-source-check.log`.

## Reproducing the watch suite

Use the existing installed device profiles and Connect IQ simulator, Java 17 on
`PATH`, and the SDK selected by the Garmin SDK Manager:

```sh
export PATH="/opt/homebrew/opt/openjdk@17/bin:$PATH"
watchshelf_sdk=$(cat "$HOME/Library/Application Support/Garmin/ConnectIQ/current-sdk.cfg")
"${watchshelf_sdk}bin/monkeyc" -d fr645m -f monkey.jungle -o /tmp/WatchShelf-b42-fr645m-tests.prg -y developer_key.der -t -w
"${watchshelf_sdk}bin/monkeydo" /tmp/WatchShelf-b42-fr645m-tests.prg fr645m -t
"${watchshelf_sdk}bin/monkeyc" -d venu445mm -f monkey.jungle -o /tmp/WatchShelf-b42-venu445mm-tests.prg -y developer_key.der -t -w
"${watchshelf_sdk}bin/monkeydo" /tmp/WatchShelf-b42-venu445mm-tests.prg venu445mm -t
```

Inspect the complete `PASSED (passed=..., failed=0, errors=0)` summary. On this
machine `monkeydo` can return process status 1 even when every test passes, so the
exit status alone is not the test result.

## Physical validation still required

Simulator tests establish state transitions and capacity checks. They do not
establish Garmin's firmware polling schedule, native connectivity, or unattended
audio playback. On a physical Venu 4 45 mm, verify:

- An ABS-downloaded episode arrives while the watch is idle and charging,
  including at full battery and with the phone absent.
- Wi-Fi loss/reconnection respects retry delays and resumes committed audio.
- Unplugging, cancelling, disabling a show, changing credentials and choosing
  **Keep on watch** during sync preserve the documented ownership rules.
- Offline completion reaches ABS before optional automatic removal; a rewind or
  failed progress exchange preserves audio.
- Repeated firmware polls and an overnight charging session do not cause tight
  retry loops, duplicate downloads or missing playback.

Automatic download and finished-episode removal settings remain off by default.
Garmin controls when a requested sync runs. Issue #78's native Wi-Fi stall remains
a separate device investigation.
