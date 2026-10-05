'use strict';

const { execFile } = require('child_process');
const { promisify } = require('util');
const execFileP = promisify(execFile);

const { HOST_PROJECT_DIR } = require('./paths');
const { parseComposePsOutput } = require('./dockerFacts');

// Read-only Docker introspection for the Monitoring section (Overview table
// + per-service Logs, wired up by a later task's routes). Every call here is
// a plain `docker`/`docker compose` read — no mutation, same "wrap, never
// reimplement" posture as dockerFacts.js, kept in its own file because these
// calls are heavier (docker inspect / docker stats) and specific to
// Monitoring rather than the Dashboard.
//
// `exec`/`now` are injectable ({ exec, now }, both defaulting to the real
// thing) so test/containerFacts.test.js runs without a Docker daemon.

const EXEC_OPTS = { cwd: HOST_PROJECT_DIR, maxBuffer: 8 * 1024 * 1024 };
const CACHE_MS = 30000; // the compose service list rarely changes; skip the shell-out on every 10s poll tick

let cache = { at: -Infinity, list: [] };
let listInFlight = null;
let overviewInFlight = null;

function _resetCache() {
  cache = { at: -Infinity, list: [] };
  listInFlight = null;
  overviewInFlight = null;
}

// `docker compose config --services` lists every service the compose file
// defines, including ones not currently running (a stopped/never-created
// container is still a row in the Overview table, via getOverview's
// state:'missing'). 'wizard' is excluded — it is this container itself, not
// part of the PadSign stack it is monitoring.
//
// Callers always get a copy (a caller sorting or pushing must not corrupt the
// cache), and overlapping calls while nothing is cached share one exec.
async function listStackServices({ exec = execFileP, now = Date.now } = {}) {
  const t = now();
  if (t - cache.at < CACHE_MS) return cache.list.slice();
  if (listInFlight) return (await listInFlight).slice();

  const pending = (async () => {
    try {
      const { stdout } = await exec('docker', ['compose', 'config', '--services'], {
        ...EXEC_OPTS,
        timeout: 10000
      });
      const list = String(stdout)
        .split(/\r?\n/)
        .map((s) => s.trim())
        .filter(Boolean)
        .filter((s) => s !== 'wizard')
        .sort();
      cache = { at: t, list };
      return list;
    } catch (err) {
      // Docker unreachable this tick — keep showing the last known list rather
      // than blanking the whole table; [] only ever means "never succeeded".
      return cache.list;
    }
  })();
  listInFlight = pending;
  try {
    return (await pending).slice();
  } finally {
    if (listInFlight === pending) listInFlight = null;
  }
}

const SIZE_UNITS = {
  B: 1,
  kB: 1000,
  KB: 1000,
  KiB: 1024,
  MB: 1000 * 1000,
  MiB: 1024 * 1024,
  GB: 1000 * 1000 * 1000,
  GiB: 1024 * 1024 * 1024,
  TB: 1000 * 1000 * 1000 * 1000,
  TiB: 1024 * 1024 * 1024 * 1024
};

// Parses docker's human-readable size strings ("123.4MiB", either half of a
// "123.4MiB / 7.6GiB" MemUsage pair). Never throws — a stats/inspect field
// is display-only, not worth crashing a 10s poll over — junk just becomes
// null so the Overview table renders an empty cell instead of a wrong one.
function parseSize(str) {
  if (typeof str !== 'string') return null;
  const m = str.trim().match(/^([0-9]*\.?[0-9]+)([A-Za-z]+)$/);
  if (!m) return null;
  const value = parseFloat(m[1]);
  const mult = SIZE_UNITS[m[2]];
  if (mult === undefined || Number.isNaN(value)) return null;
  return Math.round(value * mult);
}

// The tag separator is the LAST colon after the LAST slash — a digest
// suffix (`@sha256:...`) and a `registry:port/` prefix both contain colons
// that are not it. A real image string with no tag defaults to 'latest', same
// as Docker; a missing/empty image is null (unknown), not a made-up 'latest'.
function imageTag(image) {
  if (typeof image !== 'string' || image === '') return null;
  const withoutDigest = image.split('@')[0];
  const lastSlash = withoutDigest.lastIndexOf('/');
  const lastColon = withoutDigest.lastIndexOf(':');
  if (lastColon === -1 || lastColon < lastSlash) return 'latest';
  return withoutDigest.slice(lastColon + 1);
}

// One `docker inspect` result per container -> keyed by compose SERVICE name
// (not container id), so getOverview can join it against
// listStackServices(), which only knows service names. Falls back to the
// container's own Name (minus the leading '/') for a container started
// outside compose's labelling — shouldn't happen inside this stack, but
// better than dropping the row.
function parseInspect(inspectArray, nowMs) {
  const map = new Map();
  for (const item of inspectArray || []) {
    if (!item) continue;
    const labels = (item.Config && item.Config.Labels) || {};
    const service = labels['com.docker.compose.service']
      || (typeof item.Name === 'string' ? item.Name.replace(/^\//, '') : null);
    if (!service) continue;

    const state = item.State || {};
    const health = (state.Health && state.Health.Status) || 'none';
    const log = state.Health && Array.isArray(state.Health.Log) ? state.Health.Log : [];
    const lastEntry = log.length ? log[log.length - 1] : null;
    const lastProbe = lastEntry && typeof lastEntry.Output === 'string'
      ? lastEntry.Output.trim().slice(0, 300)
      : null;

    const startedAtMs = state.StartedAt ? Date.parse(state.StartedAt) : NaN;
    const uptimeSec = state.Running && !Number.isNaN(startedAtMs)
      ? Math.floor((nowMs - startedAtMs) / 1000)
      : null;

    const image = (item.Config && item.Config.Image) || null;

    map.set(service, {
      service,
      containerId: item.Id,
      state: state.Status || null,
      health,
      restarts: typeof item.RestartCount === 'number' ? item.RestartCount : null,
      startedAt: state.StartedAt || null,
      uptimeSec,
      image,
      imageTag: imageTag(image),
      lastProbe
    });
  }
  return map;
}

function parsePercent(str) {
  if (typeof str !== 'string') return null;
  const m = str.trim().match(/^(-?[0-9.]+)%$/);
  if (!m) return null;
  const value = parseFloat(m[1]);
  return Number.isNaN(value) ? null : value;
}

function parsePids(value) {
  const n = parseInt(value, 10);
  return Number.isNaN(n) ? null : n;
}

// `docker stats --no-stream --format '{{json .}}'` emits one JSON object per
// line — always ndjson, unlike `compose ps --format json` which varies by
// version (that variance is what parseComposePsOutput in dockerFacts.js
// already handles; stats never needs it).
function parseStats(stdout) {
  const map = new Map();
  const lines = String(stdout || '').split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  for (const line of lines) {
    let obj;
    try {
      obj = JSON.parse(line);
    } catch (err) {
      continue; // a stray non-JSON line shouldn't drop the rest of the batch
    }
    if (!obj || !obj.ID) continue;
    const [usage, limit] = String(obj.MemUsage || '').split('/').map((s) => s.trim());
    // Always the 12-char prefix, so a full-length ID (some Docker versions,
    // --no-trunc) still joins against getOverview's containerId.slice(0, 12).
    map.set(String(obj.ID).slice(0, 12), {
      cpuPct: parsePercent(obj.CPUPerc),
      memUsageBytes: parseSize(usage),
      memLimitBytes: parseSize(limit),
      memPct: parsePercent(obj.MemPerc),
      netIO: typeof obj.NetIO === 'string' ? obj.NetIO : null,
      blockIO: typeof obj.BlockIO === 'string' ? obj.BlockIO : null,
      pids: parsePids(obj.PIDs)
    });
  }
  return map;
}

// Ties the four docker calls together into one row per stack service, in the
// shape the Monitoring Overview table renders directly. Never throws: a
// failure at any one step degrades that step's fields to null/'missing'
// rather than taking the whole page down — this function is polled every
// 10s, and a flaky `docker stats` shouldn't blank the state/health columns
// that `docker inspect` already answered.
//
// Single-flight: the UI polls every 10s and a slow tick (docker stats alone
// takes ~2s) can overlap the next one, so overlapping calls share one run
// instead of piling up docker processes.
function getOverview(options = {}) {
  if (overviewInFlight) return overviewInFlight;
  const pending = computeOverview(options).finally(() => {
    if (overviewInFlight === pending) overviewInFlight = null;
  });
  overviewInFlight = pending;
  return pending;
}

function tryParseJsonArray(text) {
  if (typeof text !== 'string' || !text.trim()) return null;
  try {
    const parsed = JSON.parse(text);
    return Array.isArray(parsed) ? parsed : null;
  } catch (err) {
    return null;
  }
}

async function computeOverview({ exec = execFileP, now = Date.now } = {}) {
  const nowMs = now();
  const generatedAt = new Date(nowMs).toISOString();
  const services = await listStackServices({ exec, now: () => nowMs });

  let psRows;
  try {
    const { stdout } = await exec('docker', ['compose', 'ps', '-a', '--format', 'json'], {
      ...EXEC_OPTS,
      timeout: 10000
    });
    psRows = parseComposePsOutput(stdout);
  } catch (err) {
    // Compose itself isn't answering -> nothing downstream can be trusted
    // either; this is the wizard's existing "docker isn't reachable" signal.
    return { generatedAt, dockerAvailable: false, services: [] };
  }

  // Only containers of stack services are inspected/statted — `compose ps`
  // also lists the wizard's own container, which is neither shown nor worth a
  // docker call. When a service has several containers (a recreate leaving an
  // old one behind, or scaling), the running one is the one worth reporting.
  const stackSet = new Set(services);
  const psByService = new Map();
  for (const row of psRows) {
    if (!row || !row.Service || !row.ID || !stackSet.has(row.Service)) continue;
    const current = psByService.get(row.Service);
    if (!current || (current.State !== 'running' && row.State === 'running')) {
      psByService.set(row.Service, row);
    }
  }
  const ids = [...psByService.values()].map((row) => row.ID);

  let inspectMap = new Map();
  if (ids.length > 0) {
    try {
      const { stdout } = await exec('docker', ['inspect', ...ids], { ...EXEC_OPTS, timeout: 10000 });
      inspectMap = parseInspect(JSON.parse(stdout), nowMs);
    } catch (err) {
      // `docker inspect` exits 1 when one id vanished (a container recreated
      // between our `ps` and `inspect`) but still prints the JSON array for
      // the ids it found — salvage that instead of blanking every row.
      const partial = tryParseJsonArray(err && err.stdout);
      inspectMap = partial ? parseInspect(partial, nowMs) : new Map();
    }
  }

  const runningIds = [...inspectMap.values()]
    .filter((info) => info.state === 'running')
    .map((info) => info.containerId);

  let statsMap = new Map();
  if (runningIds.length > 0) {
    try {
      // docker stats --no-stream takes ~2s to sample, hence the longer
      // timeout than the other three calls.
      const { stdout } = await exec(
        'docker',
        ['stats', '--no-stream', '--format', '{{json .}}', ...runningIds],
        { ...EXEC_OPTS, timeout: 15000 }
      );
      statsMap = parseStats(stdout);
    } catch (err) {
      statsMap = new Map(); // cpu/mem columns show null; state/health/etc. still render
    }
  }

  const rows = services.map((service) => {
    const info = inspectMap.get(service);
    if (!info) {
      const psRow = psByService.get(service);
      // 'missing' means compose does not know a container for this service at
      // all. If compose ps listed one but inspect did not return it, show what
      // ps knows (state/health/image) rather than claiming it is gone.
      return {
        service,
        state: psRow ? (psRow.State || null) : 'missing',
        health: psRow ? (psRow.Health || 'none') : null,
        restarts: null,
        uptimeSec: null,
        imageTag: psRow ? imageTag(psRow.Image) : null,
        image: psRow ? (psRow.Image || null) : null,
        lastProbe: null,
        cpuPct: null,
        memUsageBytes: null,
        memLimitBytes: null,
        memPct: null
      };
    }
    // docker stats' own ID column is always the 12-char short id, regardless
    // of the (possibly full-length) id we passed it on the command line.
    const stats = statsMap.get(String(info.containerId || '').slice(0, 12));
    return {
      service,
      state: info.state,
      health: info.health,
      restarts: info.restarts,
      uptimeSec: info.uptimeSec,
      imageTag: info.imageTag,
      image: info.image,
      lastProbe: info.lastProbe,
      cpuPct: stats ? stats.cpuPct : null,
      memUsageBytes: stats ? stats.memUsageBytes : null,
      memLimitBytes: stats ? stats.memLimitBytes : null,
      memPct: stats ? stats.memPct : null
    };
  });

  return { generatedAt, dockerAvailable: true, services: rows };
}

module.exports = {
  listStackServices,
  getOverview,
  parseInspect,
  parseStats,
  parseSize,
  imageTag,
  _resetCache
};
