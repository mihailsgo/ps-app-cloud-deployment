'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('events');
const { PassThrough } = require('stream');

const {
  TAIL_CHOICES,
  SINCE_RE,
  validateLogParams,
  buildLogArgs,
  createLineSplitter,
  acquireStream,
  streamLogsSse,
  streamLogsDownload,
  _resetStreams
} = require('../lib/logStream');

const SERVICES = ['nginx', 'ps-server', 'ps-client'];

// ---- validateLogParams ----

test('validateLogParams: unknown service is rejected with an operator-facing message', () => {
  const result = validateLogParams({ service: 'not-a-service' }, SERVICES);
  assert.equal(result.ok, false);
  assert.equal(result.error, "Unknown service 'not-a-service'.");
});

test('validateLogParams: defaults are tail=200, since=null, follow=false', () => {
  const result = validateLogParams({ service: 'nginx' }, SERVICES);
  assert.deepEqual(result, { ok: true, params: { service: 'nginx', tail: 200, since: null, follow: false } });
});

test('validateLogParams: tail must be one of the fixed choices (query values are strings)', () => {
  const bad = validateLogParams({ service: 'nginx', tail: '300' }, SERVICES);
  assert.equal(bad.ok, false);

  for (const choice of TAIL_CHOICES) {
    const ok = validateLogParams({ service: 'nginx', tail: String(choice) }, SERVICES);
    assert.equal(ok.ok, true);
    assert.equal(ok.params.tail, choice);
  }
});

test('validateLogParams: since must match N[smhd]; "0m" is rejected (no leading zero)', () => {
  assert.equal(validateLogParams({ service: 'nginx', since: '5x' }, SERVICES).ok, false);
  assert.equal(validateLogParams({ service: 'nginx', since: '0m' }, SERVICES).ok, false);

  const ok = validateLogParams({ service: 'nginx', since: '15m' }, SERVICES);
  assert.equal(ok.ok, true);
  assert.equal(ok.params.since, '15m');
});

test('validateLogParams: since "" or absent normalizes to null', () => {
  assert.equal(validateLogParams({ service: 'nginx', since: '' }, SERVICES).params.since, null);
  assert.equal(validateLogParams({ service: 'nginx' }, SERVICES).params.since, null);
});

test('validateLogParams: follow is true only for "1" or "true"', () => {
  assert.equal(validateLogParams({ service: 'nginx', follow: '1' }, SERVICES).params.follow, true);
  assert.equal(validateLogParams({ service: 'nginx', follow: 'true' }, SERVICES).params.follow, true);
  assert.equal(validateLogParams({ service: 'nginx', follow: 'yes' }, SERVICES).params.follow, false);
  assert.equal(validateLogParams({ service: 'nginx' }, SERVICES).params.follow, false);
});

test('SINCE_RE: rejects more than 4 digits and non s/m/h/d units', () => {
  assert.equal(SINCE_RE.test('15m'), true);
  assert.equal(SINCE_RE.test('9999s'), true);
  assert.equal(SINCE_RE.test('99999s'), false);
  assert.equal(SINCE_RE.test('15mm'), false);
  assert.equal(SINCE_RE.test('m15'), false);
});

// ---- buildLogArgs ----

test('buildLogArgs: base shape with neither since nor follow', () => {
  assert.deepEqual(
    buildLogArgs({ service: 'nginx', tail: 200, since: null, follow: false }),
    ['compose', 'logs', '--no-color', '--timestamps', '--tail', '200', 'nginx']
  );
});

test('buildLogArgs: adds --since and --follow when present, in order, before the service arg', () => {
  assert.deepEqual(
    buildLogArgs({ service: 'ps-server', tail: 1000, since: '15m', follow: true }),
    ['compose', 'logs', '--no-color', '--timestamps', '--tail', '1000', '--since', '15m', '--follow', 'ps-server']
  );
});

// ---- createLineSplitter ----

test('createLineSplitter: buffers a partial line across chunks, strips \\r, flushes on end', () => {
  const seen = [];
  const splitter = createLineSplitter((lines) => seen.push(...lines));
  splitter.push('a\nb');
  splitter.push('c\r\nd');
  splitter.end();
  assert.deepEqual(seen, ['a', 'bc', 'd']);
});

test('createLineSplitter: end() is a no-op when there is no partial tail', () => {
  const seen = [];
  const splitter = createLineSplitter((lines) => seen.push(...lines));
  splitter.push('a\n');
  splitter.end();
  assert.deepEqual(seen, ['a']);
});

test('createLineSplitter: accepts Buffers, not just strings', () => {
  const seen = [];
  const splitter = createLineSplitter((lines) => seen.push(...lines));
  splitter.push(Buffer.from('one\ntwo\n', 'utf8'));
  assert.deepEqual(seen, ['one', 'two']);
});

// ---- acquireStream ----

test('acquireStream: caps at 4 per session; a 5th for the same session is refused', () => {
  _resetStreams();
  const releases = [acquireStream('s1'), acquireStream('s1'), acquireStream('s1'), acquireStream('s1')];
  assert.ok(releases.every(Boolean));
  assert.equal(acquireStream('s1'), null);
  releases.forEach((r) => r());
});

test('acquireStream: caps at 8 total; a 9th overall is refused even from a brand-new session', () => {
  _resetStreams();
  const releases = [];
  for (const sess of ['s1', 's2']) {
    for (let i = 0; i < 4; i++) releases.push(acquireStream(sess));
  }
  assert.ok(releases.every(Boolean), 'all 8 slots (4 + 4) should be granted');
  assert.equal(acquireStream('s3'), null);
  releases.forEach((r) => r());
});

test('acquireStream: release() frees a slot; a double release does not free two', () => {
  _resetStreams();
  const releases = [];
  for (let i = 0; i < 4; i++) releases.push(acquireStream('s1'));
  assert.equal(acquireStream('s1'), null, 'at the per-session cap');

  releases[0]();
  assert.ok(acquireStream('s1'), 'the freed slot can be reacquired');
  assert.equal(acquireStream('s1'), null, 'back at the cap');

  releases[0](); // already released above
  releases[0]();
  assert.equal(acquireStream('s1'), null, 'a double release must not have freed a second slot');
});

// ---- streamLogsSse ----

function makeFakeRes() {
  return {
    headers: {},
    written: [],
    ended: false,
    flushed: false,
    setHeader(name, value) { this.headers[name] = value; },
    flushHeaders() { this.flushed = true; },
    write(chunk) { this.written.push(chunk.toString()); },
    end() { this.ended = true; }
  };
}

function makeFakeChild() {
  const child = new EventEmitter();
  child.stdout = new PassThrough();
  child.stderr = new PassThrough();
  child.killCalls = [];
  child.kill = (sig) => child.killCalls.push(sig);
  return child;
}

const tick = (ms = 15) => new Promise((resolve) => setTimeout(resolve, ms));

test('streamLogsSse: sets SSE headers and flushes them immediately', () => {
  const req = new EventEmitter();
  const res = makeFakeRes();
  const child = makeFakeChild();

  streamLogsSse(req, res, { service: 'nginx', tail: 200, since: null, follow: true },
    { spawn: () => child, cwd: '/repo', heartbeatMs: 1e9 });

  assert.equal(res.headers['Content-Type'], 'text/event-stream');
  assert.equal(res.headers['Cache-Control'], 'no-cache');
  assert.equal(res.headers['Connection'], 'keep-alive');
  assert.equal(res.headers['X-Accel-Buffering'], 'no');
  assert.equal(res.flushed, true);

  req.emit('close'); // stop the interval so the test process can exit
});

test('streamLogsSse: two stdout chunks that together form one line produce one "lines" event', async () => {
  const req = new EventEmitter();
  const res = makeFakeRes();
  const child = makeFakeChild();
  let spawnArgs = null;
  const spawn = (file, args) => { spawnArgs = args; return child; };

  streamLogsSse(req, res, { service: 'nginx', tail: 200, since: null, follow: true },
    { spawn, cwd: '/repo', heartbeatMs: 1e9 });

  assert.deepEqual(spawnArgs, buildLogArgs({ service: 'nginx', tail: 200, since: null, follow: true }));

  child.stdout.write('hello ');
  child.stdout.write('world\n');
  await tick();

  const linesEvents = res.written.filter((w) => w.startsWith('event: lines'));
  assert.equal(linesEvents.length, 1, 'only the second chunk completes a line');
  assert.match(linesEvents[0], /"lines":\["hello world"\]/);

  req.emit('close');
});

test('streamLogsSse: child "close" flushes trailing partial lines and emits "end" with the exit code', async () => {
  const req = new EventEmitter();
  const res = makeFakeRes();
  const child = makeFakeChild();

  streamLogsSse(req, res, { service: 'nginx', tail: 200, since: null, follow: false },
    { spawn: () => child, cwd: '/repo', heartbeatMs: 1e9 });

  child.stdout.write('no trailing newline');
  await tick();
  child.emit('close', 0);

  const linesEvents = res.written.filter((w) => w.startsWith('event: lines'));
  assert.ok(linesEvents.some((w) => w.includes('"no trailing newline"')), 'the unterminated tail is flushed on close');

  const endEvent = res.written.find((w) => w.startsWith('event: end'));
  assert.ok(endEvent);
  assert.match(endEvent, /"code":0/);
  assert.equal(res.ended, true);
});

test('streamLogsSse: req "close" kills a still-running child', () => {
  const req = new EventEmitter();
  const res = makeFakeRes();
  const child = makeFakeChild();

  streamLogsSse(req, res, { service: 'nginx', tail: 200, since: null, follow: true },
    { spawn: () => child, cwd: '/repo', heartbeatMs: 1e9 });

  req.emit('close');
  assert.deepEqual(child.killCalls, ['SIGTERM']);
});

test('streamLogsSse: req "close" after the child already exited does not kill it again', () => {
  const req = new EventEmitter();
  const res = makeFakeRes();
  const child = makeFakeChild();

  streamLogsSse(req, res, { service: 'nginx', tail: 200, since: null, follow: false },
    { spawn: () => child, cwd: '/repo', heartbeatMs: 1e9 });

  child.emit('close', 0);
  req.emit('close');
  assert.deepEqual(child.killCalls, [], 'the child already exited; killing it again is pointless');
});

test('streamLogsSse: child "error" emits an error event, ends the response, never writes after', async () => {
  const req = new EventEmitter();
  const res = makeFakeRes();
  const child = makeFakeChild();

  streamLogsSse(req, res, { service: 'nginx', tail: 200, since: null, follow: false },
    { spawn: () => child, cwd: '/repo', heartbeatMs: 5 });

  child.emit('error', new Error('spawn ENOENT'));

  const errorEvent = res.written.find((w) => w.startsWith('event: error'));
  assert.ok(errorEvent);
  assert.match(errorEvent, /spawn ENOENT/);
  assert.equal(res.ended, true);

  const countAfterEnd = res.written.length;
  await tick(30); // a heartbeat firing here would mean the interval wasn't cleared
  assert.equal(res.written.length, countAfterEnd, 'nothing is written after res.end()');
});

test('streamLogsSse: heartbeat writes ": hb" on the configured interval', async () => {
  const req = new EventEmitter();
  const res = makeFakeRes();
  const child = makeFakeChild();

  streamLogsSse(req, res, { service: 'nginx', tail: 200, since: null, follow: true },
    { spawn: () => child, cwd: '/repo', heartbeatMs: 10 });

  await tick(45);
  req.emit('close'); // clears the interval and kills the child so the process can exit

  assert.ok(res.written.some((w) => w === ': hb\n\n'));
});

// ---- streamLogsDownload ----

test('streamLogsDownload: forces follow=false, sets download headers with a UTC timestamp, pipes stdout+stderr', async () => {
  const res = new PassThrough();
  res.headers = {};
  res.setHeader = (name, value) => { res.headers[name] = value; };

  const child = makeFakeChild();
  let spawnArgs = null;
  const spawn = (file, args) => { spawnArgs = args; return child; };

  const now = () => Date.parse('2026-09-29T08:07:09.000Z');
  streamLogsDownload(res, { service: 'ps-server', tail: 1000, since: '15m', follow: true },
    { spawn, cwd: '/repo', now });

  assert.deepEqual(spawnArgs, ['compose', 'logs', '--no-color', '--timestamps', '--tail', '1000', '--since', '15m', 'ps-server']);
  assert.equal(res.headers['Content-Type'], 'text/plain; charset=utf-8');
  assert.equal(res.headers['Content-Disposition'], 'attachment; filename="ps-server-20260929-080709.log"');

  const chunks = [];
  res.on('data', (c) => chunks.push(c));

  child.stdout.write('log line 1\n');
  child.stderr.write('a warning on stderr\n');
  child.stdout.end('log line 2\n');
  await tick();
  child.emit('close', 0);
  await tick();

  const body = Buffer.concat(chunks).toString('utf8');
  assert.match(body, /log line 1/);
  assert.match(body, /a warning on stderr/);
  assert.match(body, /log line 2/);
});
