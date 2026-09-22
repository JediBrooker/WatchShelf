# Debug symbols

One `<tag>-<device>.debug.xml` per build (`Versions.tag` in
[`source/Constants.mc`](../source/Constants.mc)). These turn a crash log off a
user's watch into file-and-line stack frames.

## Why the device is in the name

**Program counters are per-device.** The same source built for `vivoactive4`
and for `fr965` puts `deleteBook` at `268447414` and `268444875` respectively.
Decoding a log against another device's symbols yields confident, *wrong*
`file:line` — worse than no answer at all. Each `.debug.xml` records the
`partNumber` it was built for, and `tools/decode-crash.py` refuses to decode a
log from a different one.

`make build` writes the current tag+device file here automatically. **Commit it
along with the build.**

## Decoding a crash log

Ask the reporter for the build tag shown in the app and for
`GARMIN/APPS/LOGS/CIQ_LOG.YML` copied off the watch over USB. The log's
`Part-Number:` names their device.

```bash
tools/decode-crash.py CIQ_LOG.YML debug-symbols/b35-fenix8solar51mm.debug.xml
```

```
Error: 'Media Error Occurred'
Part-Number: 006-B3225-00

3 frame(s), decoded against b35-vivoactive4.debug.xml [006-B3225-00 (vivoactive4)]:

  #0  0x100000b4  <init>() at source/ContentIterator.mc:20
  #1  0x100038cb  next() at source/ContentIterator.mc:104
```

If you don't have that tag+device combination, build it — see below — rather
than reaching for the nearest file.

By hand it's the same lookup: take a `pc:` from the log, convert **hex** to
**decimal** (the log is hex, `debug.xml` is decimal — the step that catches
everyone out), find the `<entry>` in `<pcToLineNum>` with the nearest `pc`, and
read its `filename` / `lineNum` / `symbol`. A pc can land mid-instruction or on
a return address, so the nearest entry at or below is the usual answer and the
next one up is the alternative.

For store builds there is also Garmin's
[Error Reporting Application](https://developer.garmin.com/connect-iq/core-topics/exception-reporting-tool/),
which symbolicates automatically from the `debug.xml` inside the uploaded `.iq`.

## Regenerating symbols for a tag

Symbols are reproducible from source, so any missing tag+device can be rebuilt
**as long as you can check out that tag's source**:

```bash
make build DEVICE=vivoactive4      # writes debug-symbols/<tag>-vivoactive4.debug.xml
```

`b35` is the current `main`, so its symbols can be produced for any device on
demand. **Earlier builds are not tagged in git**, which is the real gap — please
`git tag b36`, `b37`, … as you ship, so a future crash report stays decodable
even for a device nobody built at the time.

## Coverage

| Tag | Devices |
|---|---|
| b24–b28 | `fenix8solar51mm` only (part number `006-B4533-00`) — the old files predate per-device naming |
| b29–b34 | **none**, and not reproducible: archiving had lapsed and these commits aren't tagged |
| b35 | `fenix8solar51mm`; any other device is one `make build DEVICE=…` away |
