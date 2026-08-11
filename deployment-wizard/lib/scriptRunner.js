'use strict';

const { spawn } = require('child_process');
const fs = require('fs');
const { parseLine } = require('./outputParser');
const { HOST_PROJECT_DIR, projectPath } = require('./paths');

// The only module allowed to spawn bootstrap.sh/upgrade.sh (decision #5:
// wrap, never reimplement). Everything else about "what's deployed" comes
// from dockerFacts.js/stateDetector.js reading live state, not from here.

const LOCK_FILE = projectPath('.wizard-run.lock');
const MAX_BUFFERED_EVENTS = 5000; // ring buffer per run, for late/reconnecting SSE clients

const runs = new Map(); // runId -> RunState
let activeRunId = null;

function makeRunId() {
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

function isRunActive() {
  return Boolean(activeRunId && runs.has(activeRunId) && !runs.get(activeRunId).done);
}

function writeLockFile(runId, scriptName) {
  try {
    fs.writeFileSync(
      LOCK_FILE,
      JSON.stringify({ runId, scriptName, pid: process.pid, startedAt: Date.now() })
    );
  } catch (err) {
    // Non-fatal — the lock file is a best-effort "was a run in progress"
    // signal for after a wizard-container restart, not the source of truth.
  }
}

function clearLockFile() {
  try {
    fs.unlinkSync(LOCK_FILE);
  } catch (err) {
    // already gone — fine
  }
}

// Best-effort signal for the dashboard: "a run was in progress when this
// wizard process last started; it may have completed or failed while the
// wizard was down — check `docker compose logs` / re-run if needed."
function staleLockInfo() {
  try {
    const raw = fs.readFileSync(LOCK_FILE, 'utf8');
    return JSON.parse(raw);
  } catch (err) {
    return null;
  }
}

function pushEvent(state, event, data) {
  const item = { seq: state.seq++, event, data };
  state.buffer.push(item);
  if (state.buffer.length > MAX_BUFFERED_EVENTS) state.buffer.shift();
  for (const listener of state.listeners) listener(item);
}

function startRun({ scriptName, args, onEvent }) {
  if (isRunActive()) {
    const err = new Error('A deploy/upgrade run is already in progress.');
    err.code = 'RUN_IN_PROGRESS';
    throw err;
  }

  const scriptPath = projectPath('installation-scripts', scriptName);
  const runId = makeRunId();
  const proc = spawn('bash', [scriptPath, ...args], { cwd: HOST_PROJECT_DIR });

  const state = {
    runId,
    scriptName,
    args,
    buffer: [],
    listeners: new Set(),
    seq: 0,
    done: false,
    exitCode: null,
    startedAt: Date.now()
  };
  runs.set(runId, state);
  activeRunId = runId;
  writeLockFile(runId, scriptName);

  const lineBuffers = { stdout: '', stderr: '' };

  const flushLine = (streamName, line) => {
    if (line === '') return;
    const parsed = parseLine(line);
    pushEvent(state, parsed.type, parsed);
    pushEvent(state, 'log', { stream: streamName, line });
  };

  const handleChunk = (streamName) => (chunk) => {
    lineBuffers[streamName] += chunk.toString('utf8');
    const parts = lineBuffers[streamName].split(/\r?\n/);
    lineBuffers[streamName] = parts.pop(); // last element may be a partial line — keep buffered
    for (const line of parts) flushLine(streamName, line);
  };

  proc.stdout.on('data', handleChunk('stdout'));
  proc.stderr.on('data', handleChunk('stderr'));

  const finish = (exitCode) => {
    if (state.done) return; // 'close' and a synthetic error-path finish should not double-fire
    // flush any trailing partial line (process exited without a final newline)
    if (lineBuffers.stdout) flushLine('stdout', lineBuffers.stdout);
    if (lineBuffers.stderr) flushLine('stderr', lineBuffers.stderr);
    state.done = true;
    state.exitCode = exitCode;
    pushEvent(state, 'done', { exitCode, success: exitCode === 0 });
    if (activeRunId === runId) activeRunId = null;
    clearLockFile();
  };

  proc.on('close', (code) => finish(code));
  proc.on('error', (err) => {
    pushEvent(state, 'error', { message: `Failed to start ${scriptName}: ${err.message}` });
    finish(-1);
  });

  if (onEvent) subscribe(runId, onEvent);
  return runId;
}

// Replays the buffered events (so a client connecting mid-run or
// reconnecting doesn't miss anything), then streams new events live.
// Returns an unsubscribe function.
function subscribe(runId, listener) {
  const state = runs.get(runId);
  if (!state) return () => {};
  for (const item of state.buffer) listener(item);
  state.listeners.add(listener);
  return () => state.listeners.delete(listener);
}

function getRun(runId) {
  return runs.get(runId) || null;
}

function getActiveRunId() {
  return isRunActive() ? activeRunId : null;
}

module.exports = { startRun, subscribe, getRun, isRunActive, getActiveRunId, staleLockInfo };
