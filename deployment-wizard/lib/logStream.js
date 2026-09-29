'use strict';

const { spawn: nodeSpawn } = require('child_process');
const { StringDecoder } = require('string_decoder');

const { HOST_PROJECT_DIR } = require('./paths');

// Live per-service log viewer for the Monitoring section (SSE) plus a
// one-shot download. Spawns `docker compose logs` directly rather than going
// through lib/scriptRunner.js: scriptRunner enforces a single global run
// lock meant for a mutating bootstrap.sh/upgrade.sh run, which is wrong for
// a read-only, possibly-long-lived (`--follow`) tail — several Logs tabs
// (and a deploy run) must all be able to be open at once. Same reasoning as
// lib/upgradePlan.js's execFile-direct approach.

const TAIL_CHOICES = [200, 1000, 5000];
// One to four digits, no leading zero (so "0m" is rejected as meaningless),
// followed by a single s/m/h/d unit — the exact shape `docker compose logs
// --since` accepts for a relative duration.
const SINCE_RE = /^(?:[1-9][0-9]{0,3}[smhd])$/;

// Raw query input is echoed back in error messages, so cap it: a multi-KB
// value in a URL should not become a multi-KB error body.
function describeForError(value) {
  if (value === undefined) return 'undefined';
  let s;
  if (typeof value === 'string') {
    s = value;
  } else {
    try {
      s = JSON.stringify(value);
    } catch (err) {
      s = undefined;
    }
    if (typeof s !== 'string') s = String(value);
  }
  return s.length > 80 ? `${s.slice(0, 80)}…` : s;
}

// `query` is an Express req.query object: values are normally strings, but
// Express parses `?since[]=15m` into an ARRAY — and both Number(['1000']) and
// SINCE_RE.test(['15m']) coerce a one-element array back to a matching string,
// so every field is type-checked before any coercion happens.
// `services` is the live stack service list from
// containerFacts.listStackServices() — validating against it means a typo'd
// or stale service name is rejected before anything gets spawned.
function validateLogParams(query, services) {
  const q = query || {};
  const service = q.service;
  if (typeof service !== 'string' || !services.includes(service)) {
    return { ok: false, error: `Unknown service '${describeForError(service)}'.` };
  }

  let tail = 200;
  if (q.tail !== undefined && q.tail !== '') {
    const n = typeof q.tail === 'string' ? Number(q.tail) : NaN;
    if (!TAIL_CHOICES.includes(n)) {
      return { ok: false, error: `Invalid tail length '${describeForError(q.tail)}'. Choose one of ${TAIL_CHOICES.join(', ')}.` };
    }
    tail = n;
  }

  let since = null;
  if (q.since !== undefined && q.since !== '') {
    if (typeof q.since !== 'string' || !SINCE_RE.test(q.since)) {
      return { ok: false, error: `Invalid since value '${describeForError(q.since)}'. Use a number followed by s/m/h/d, e.g. "15m".` };
    }
    since = q.since;
  }

  const follow = q.follow === '1' || q.follow === 'true';

  return { ok: true, params: { service, tail, since, follow } };
}

function buildLogArgs({ service, tail, since, follow }) {
  return [
    'compose', 'logs', '--no-color', '--timestamps',
    '--tail', String(tail),
    ...(since ? ['--since', since] : []),
    ...(follow ? ['--follow'] : []),
    service
  ];
}

// Buffers a partial line across chunks (the trailing split segment may not
// end on a newline yet) and hands complete lines to `onLines` in batches —
// one call per push(), not one call per line, so a caller can turn each
// push into a single SSE event. `\r` is stripped so a CRLF source doesn't
// leave a stray `\r` at the end of a line. Buffer chunks go through a
// StringDecoder, which holds back an incomplete trailing multi-byte sequence
// until its remaining bytes arrive — a plain chunk.toString() would turn a
// character split across two reads (e.g. Latvian "ī") into U+FFFD garbage.
function createLineSplitter(onLines) {
  const decoder = new StringDecoder('utf8');
  let buffer = '';
  return {
    push(chunk) {
      buffer += Buffer.isBuffer(chunk) ? decoder.write(chunk) : String(chunk);
      const parts = buffer.split(/\r?\n/);
      buffer = parts.pop();
      if (parts.length > 0) onLines(parts);
    },
    end() {
      buffer += decoder.end();
      if (buffer !== '') {
        onLines([buffer]);
        buffer = '';
      }
    }
  };
}

// Every open Logs tab holds a `docker compose logs -f` process alive on the
// HOST for as long as the browser tab stays open — these caps stop a
// forgotten tab farm (or a reconnect-loop bug in the client) from
// exhausting host processes. Per-session bounds one careless operator;
// the global cap bounds all operators together.
const MAX_PER_SESSION = 4;
const MAX_TOTAL = 8;

let totalActive = 0;
const activeBySession = new Map();

function _resetStreams() {
  totalActive = 0;
  activeBySession.clear();
}

// Returns a release() function on success, or null when a cap is hit.
// release() is idempotent: calling it twice must not free two slots (a
// route calling it from both a 'close' handler and a manual cleanup path
// is easy to get wrong otherwise).
function acquireStream(sessionId) {
  const current = activeBySession.get(sessionId) || 0;
  if (current >= MAX_PER_SESSION || totalActive >= MAX_TOTAL) return null;

  activeBySession.set(sessionId, current + 1);
  totalActive += 1;

  let released = false;
  return function release() {
    if (released) return;
    released = true;
    totalActive -= 1;
    const remaining = (activeBySession.get(sessionId) || 1) - 1;
    if (remaining <= 0) activeBySession.delete(sessionId);
    else activeBySession.set(sessionId, remaining);
  };
}

// Streams `docker compose logs` to the client as Server-Sent Events. Caller
// is responsible for acquireStream()/release() around this (session/stream
// accounting is a separate concern from the mechanics of one stream).
//
// cwd defaults to the project root: the wizard process itself runs from its
// own image directory, where `docker compose logs` would find no project.
function streamLogsSse(req, res, params, { spawn = nodeSpawn, cwd = HOST_PROJECT_DIR, heartbeatMs = 15000 } = {}) {
  // The client can disappear while the route awaits (service list lookup,
  // slot acquisition); spawning a follow process for a dead socket would leak
  // it, because 'close' has already fired and will not fire again.
  if (req.destroyed || res.destroyed || res.writableEnded) return null;

  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.setHeader('X-Accel-Buffering', 'no'); // nginx: do not buffer the SSE body
  res.flushHeaders();

  const child = spawn('docker', buildLogArgs(params), { cwd });

  let responseEnded = false;
  let childExited = false;
  let drainPending = false;

  // When the client cannot keep up, res.write() returns false. Stop reading
  // the child's pipes (so the OS pipe fills and docker blocks) instead of
  // buffering unbounded log output in this process; resume on 'drain'. The
  // flag keeps repeated backpressure from stacking listeners.
  const safeWrite = (data) => {
    if (responseEnded) return;
    const ok = res.write(data);
    if (ok === false && !drainPending) {
      drainPending = true;
      child.stdout.pause();
      child.stderr.pause();
      res.once('drain', () => {
        drainPending = false;
        child.stdout.resume();
        child.stderr.resume();
      });
    }
  };

  // A batch bigger than 500 lines (e.g. the initial --tail 5000 backlog
  // replayed on connect) is split across several events instead of one
  // unbounded payload.
  const sendLines = (lines) => {
    for (let i = 0; i < lines.length; i += 500) {
      safeWrite(`event: lines\ndata: ${JSON.stringify({ lines: lines.slice(i, i + 500) })}\n\n`);
    }
  };

  const stdoutSplitter = createLineSplitter(sendLines);
  const stderrSplitter = createLineSplitter(sendLines);
  child.stdout.on('data', (chunk) => stdoutSplitter.push(chunk));
  child.stderr.on('data', (chunk) => stderrSplitter.push(chunk));

  const heartbeat = setInterval(() => safeWrite(': hb\n\n'), heartbeatMs);

  child.on('close', (code) => {
    childExited = true;
    clearInterval(heartbeat);
    stdoutSplitter.end();
    stderrSplitter.end();
    if (responseEnded) return; // client already gone; nothing left to tell it
    safeWrite(`event: end\ndata: ${JSON.stringify({ code })}\n\n`);
    responseEnded = true;
    res.end();
  });

  child.on('error', (err) => {
    childExited = true;
    clearInterval(heartbeat);
    if (responseEnded) return;
    safeWrite(`event: error\ndata: ${JSON.stringify({ message: err.message })}\n\n`);
    responseEnded = true;
    res.end();
  });

  // Either side closing means the client is gone (req 'close' can be
  // reported before or after res 'close' depending on Node version and
  // proxy behaviour), so both trigger the same cleanup.
  const onClientClose = () => {
    responseEnded = true;
    clearInterval(heartbeat);
    // The child may already have exited on its own — killing a dead pid
    // again is harmless but pointless, so only do it while it still runs.
    if (!childExited) child.kill('SIGTERM');
  };
  req.on('close', onClientClose);
  res.on('close', onClientClose);

  return child;
}

function pad2(n) {
  return String(n).padStart(2, '0');
}

// One-shot "download the current log tail as a file" — same underlying
// `docker compose logs` call as the SSE view, just with --follow forced off
// and the output piped as a plain-text attachment instead of SSE frames.
function streamLogsDownload(res, params, { spawn = nodeSpawn, cwd = HOST_PROJECT_DIR, now = Date.now } = {}) {
  const d = new Date(now());
  const stamp = `${d.getUTCFullYear()}${pad2(d.getUTCMonth() + 1)}${pad2(d.getUTCDate())}` +
    `-${pad2(d.getUTCHours())}${pad2(d.getUTCMinutes())}${pad2(d.getUTCSeconds())}`;
  const filename = `${params.service}-${stamp}.log`;

  res.setHeader('Content-Type', 'text/plain; charset=utf-8');
  res.setHeader('Content-Disposition', `attachment; filename="${filename}"`);
  res.setHeader('Cache-Control', 'no-store'); // logs can contain secrets; keep them out of shared caches

  const child = spawn('docker', buildLogArgs({ ...params, follow: false }), { cwd });
  let ended = false;
  // end:false so a stdout 'end' doesn't close res before stderr has also
  // finished writing; res.end() waits for the child's own 'close' instead.
  child.stdout.pipe(res, { end: false });
  child.stderr.on('data', (chunk) => res.write(chunk));
  child.on('close', () => {
    if (ended) return;
    ended = true;
    res.end();
  });

  // A ChildProcess with no 'error' listener rethrows, which would take the
  // whole wizard down (e.g. `docker` missing from PATH). Node may also emit
  // 'close' after 'error', hence the `ended` guard.
  child.on('error', (err) => {
    if (ended) return;
    ended = true;
    res.write(`Could not read logs: ${err.message}\n`);
    res.end();
  });

  // Client aborted the download: stop the process instead of letting it run
  // to completion. exitCode/signalCode are both null only while it is alive.
  res.on('close', () => {
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
  });

  return child;
}

module.exports = {
  TAIL_CHOICES,
  SINCE_RE,
  validateLogParams,
  buildLogArgs,
  createLineSplitter,
  acquireStream,
  streamLogsSse,
  streamLogsDownload,
  _resetStreams
};
