import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// `node --test` runs each test file in its own process, in parallel. Every
// sidecar sweeps watchshelf-*.m4a out of tmpdir() when it starts (server.js),
// so sidecars sharing /tmp delete each other's in-flight transcodes: ffmpeg
// fails with "Unable to re-open ... output file for shifting data" and the
// request returns 502. Pass the returned directory as TMPDIR to every spawned
// sidecar, and remove it when the test file is done.
export const sidecarTmpdir = () => mkdtempSync(join(tmpdir(), 'watchshelf-test-'));
