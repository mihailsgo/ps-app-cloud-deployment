'use strict';

/*
 * Helpers shared by the four Monitoring pages (public/monitoring.js holds the
 * per-page code). Loaded first, as a plain script: no modules, no build step.
 *
 * The functions that only compute (formatters, classification, URL building)
 * take and return plain values so they can be unit-tested in Node; the file
 * ends with a guarded module.exports for that. escapeHtml() and the DOM come
 * from the browser (wizard-ui.js is loaded by every page's head partial).
 */

// ---------------------------------------------------------------------------
// Formatters
// ---------------------------------------------------------------------------

var MON_DASH = '–';

function fmtBytes(n) {
  if (typeof n !== 'number' || !isFinite(n) || n < 0) return MON_DASH;
  if (n < 1024) return Math.round(n) + ' B';
  var units = ['KiB', 'MiB', 'GiB', 'TiB'];
  var value = n;
  var i = -1;
  do {
    value /= 1024;
    i += 1;
  } while (value >= 1024 && i < units.length - 1);
  return value.toFixed(1) + ' ' + units[i];
}

// 3d 4h, 5h 12m, 7m, 42s: the two largest units, like `docker ps` does.
function fmtDuration(sec) {
  if (typeof sec !== 'number' || !isFinite(sec) || sec < 0) return MON_DASH;
  var s = Math.floor(sec);
  var d = Math.floor(s / 86400);
  var h = Math.floor((s % 86400) / 3600);
  var m = Math.floor((s % 3600) / 60);
  if (d > 0) return d + 'd ' + h + 'h';
  if (h > 0) return h + 'h ' + m + 'm';
  if (m > 0) return m + 'm';
  return s + 's';
}

function fmtPct(n) {
  if (typeof n !== 'number' || !isFinite(n)) return MON_DASH;
  return n.toFixed(1) + '%';
}

function pad2(n) {
  return (n < 10 ? '0' : '') + n;
}

// YYYY-MM-DD HH:MM:SS in UTC. The audit log and the wizard both work in UTC;
// showing local time here would disagree with the CSV export.
function fmtTime(iso) {
  var d = new Date(iso);
  if (iso === null || iso === undefined || isNaN(d.getTime())) return MON_DASH;
  return d.getUTCFullYear() + '-' + pad2(d.getUTCMonth() + 1) + '-' + pad2(d.getUTCDate()) +
    ' ' + pad2(d.getUTCHours()) + ':' + pad2(d.getUTCMinutes()) + ':' + pad2(d.getUTCSeconds());
}

// ---------------------------------------------------------------------------
// Overview: what a service row and an alert look like
// ---------------------------------------------------------------------------

// Pill = { cls, text, title }. The text always says what the state is; the
// colour class only reinforces it.
function stateClass(state) {
  if (state === 'running') return 'pill-ok';
  if (state === 'restarting' || state === 'paused' || state === 'created') return 'pill-warn';
  return 'pill-fail'; // exited, dead, removing, missing, anything unexpected
}

function healthPill(row) {
  var health = row.health;
  if (health === 'healthy') return { cls: 'pill-ok', text: 'healthy', title: row.lastProbe || '' };
  if (health === 'starting') return { cls: 'pill-warn', text: 'starting', title: row.lastProbe || '' };
  if (health === 'unhealthy') return { cls: 'pill-fail', text: 'unhealthy', title: row.lastProbe || '' };
  if (row.state === 'running') {
    // No HEALTHCHECK defined: a running container is as good as it can be
    // reported, and must not look like a failure.
    return { cls: 'pill-ok', text: 'running', title: 'This service defines no health check.' };
  }
  return { cls: 'pill-muted', text: MON_DASH, title: '' };
}

function statePill(row) {
  return { cls: stateClass(row.state), text: row.state || 'unknown', title: '' };
}

// Same rule as lib/monitorStatus.js alertSeverity(): only "something is
// down" is a failure, every other threshold is a warning.
function alertSeverity(key) {
  return key === 'service_down' || key === 'service_unhealthy' ? 'fail' : 'warn';
}

var MON_RESTART_IMPACT = {
  'ps-server': 'Restarting ps-server interrupts any document being signed right now. The tablets reconnect on their own.',
  keycloak: 'Signed-in users may have to sign in again.',
  nginx: 'The portal is unreachable for a few seconds.'
};
var MON_RESTART_DEFAULT = 'The service is unavailable until its health check passes again, usually under a minute; DMSS services can take several minutes.';

function restartImpact(service) {
  return Object.prototype.hasOwnProperty.call(MON_RESTART_IMPACT, service) ? MON_RESTART_IMPACT[service] : MON_RESTART_DEFAULT;
}

// ---------------------------------------------------------------------------
// In-place table refresh
// ---------------------------------------------------------------------------

// Which keyed rows to add, remove or keep when a table goes from `prevKeys`
// to `nextKeys`. `keep` and `add` follow the new order. Keys are service
// names, i.e. data, so lookups use a prototype-less object.
function diffRows(prevKeys, nextKeys) {
  var prev = Object.create(null);
  var next = Object.create(null);
  prevKeys.forEach(function (k) { prev[k] = true; });
  nextKeys.forEach(function (k) { next[k] = true; });
  return {
    add: nextKeys.filter(function (k) { return !prev[k]; }),
    remove: prevKeys.filter(function (k) { return !next[k]; }),
    keep: nextKeys.filter(function (k) { return prev[k]; })
  };
}

// Indexes of the cells whose content differs; a row that has no previous
// cells (new) reports all of them.
function changedIndexes(prevCells, nextCells) {
  var prev = prevCells || [];
  var out = [];
  for (var i = 0; i < nextCells.length; i += 1) {
    if (prev[i] !== nextCells[i]) out.push(i);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Logs
// ---------------------------------------------------------------------------

var LOG_ERROR_RE = /\b(ERROR|FATAL|SEVERE|\w*Exception)\b|\[error\]|level=error/i;
var LOG_WARN_RE = /\bWARN(ING)?\b|\[warn\]/i;
var LOG_LINE_CAP = 10000;
var LOG_STICKY_PX = 40;

// '' (a plain line), 'error' or 'warn'. An error wins when a line has both.
function classifyLogLine(line) {
  var text = String(line);
  if (LOG_ERROR_RE.test(text)) return 'error';
  if (LOG_WARN_RE.test(text)) return 'warn';
  return '';
}

function logQuery(state) {
  var q = new URLSearchParams();
  q.set('service', state.service);
  q.set('tail', String(state.tail));
  if (state.since) q.set('since', state.since);
  if (state.follow) q.set('follow', '1');
  return q.toString();
}

function logStreamUrl(state) {
  return '/api/monitoring/logs/stream?' + logQuery(state);
}

// The file is a snapshot: following makes no sense for it.
function logDownloadUrl(state) {
  return '/api/monitoring/logs/download?' + logQuery({ service: state.service, tail: state.tail, since: state.since, follow: false });
}

function escapeRegExp(s) {
  return String(s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

// Escapes first and only then adds <mark>, so a log line can never inject
// markup. Returns an HTML string.
function highlightLine(text, filter) {
  var raw = String(text);
  if (!filter) return escapeHtml(raw);
  var re = new RegExp(escapeRegExp(filter), 'gi');
  var out = '';
  var last = 0;
  var m;
  while ((m = re.exec(raw)) !== null) {
    out += escapeHtml(raw.slice(last, m.index)) + '<mark>' + escapeHtml(m[0]) + '</mark>';
    last = m.index + m[0].length;
    if (m[0].length === 0) re.lastIndex += 1;
  }
  return out + escapeHtml(raw.slice(last));
}

// Whether a line is shown given the text filter and the "errors and
// warnings only" switch. `cls` is classifyLogLine(text).
function logLineVisible(text, cls, filter, errorsOnly) {
  if (errorsOnly && !cls) return false;
  if (filter && String(text).toLowerCase().indexOf(String(filter).toLowerCase()) === -1) return false;
  return true;
}

function nearBottom(scrollHeight, scrollTop, clientHeight) {
  return scrollHeight - scrollTop - clientHeight <= LOG_STICKY_PX;
}

// ---------------------------------------------------------------------------
// Signing activity
// ---------------------------------------------------------------------------

function isoDate(d) {
  return d.getUTCFullYear() + '-' + pad2(d.getUTCMonth() + 1) + '-' + pad2(d.getUTCDate());
}

// The server defaults to the same window; the form shows it so the operator
// sees what is being filtered.
function activityDefaults(now) {
  var to = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
  var from = new Date(to.getTime() - 29 * 86400000);
  return { from: isoDate(from), to: isoDate(to) };
}

function activityQuery(filters, page) {
  var q = new URLSearchParams();
  ['from', 'to', 'company', 'user', 'outcome'].forEach(function (key) {
    if (filters[key]) q.set(key, filters[key]);
  });
  if (page && page > 1) q.set('page', String(page));
  return q.toString();
}

function csvHref(filters) {
  var q = activityQuery(filters, 1);
  return '/api/monitoring/activity.csv' + (q ? '?' + q : '');
}

var ACT_OUTCOMES = ['completed', 'failed', 'pending'];
var ACT_TEXT_MAX = 200;

// Exactly YYYY-MM-DD and a real calendar day (2026-02-30 is not one).
function isIsoDate(s) {
  if (typeof s !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(s)) return false;
  var d = new Date(s + 'T00:00:00Z');
  return !isNaN(d.getTime()) && isoDate(d) === s;
}

function clipText(s) {
  return String(s === null || s === undefined ? '' : s).trim().slice(0, ACT_TEXT_MAX);
}

// The filters and page a URL asks for. `search` is location.search. Every
// value is validated; whatever is missing or malformed falls back to the
// defaults (dates) or to "no filter" (the rest), so a hand-edited or stale
// link never breaks the page.
function parseActivityParams(search, defaults) {
  var q = new URLSearchParams(search || '');
  var from = q.get('from');
  var to = q.get('to');
  var outcome = q.get('outcome');
  var page = q.get('page');
  return {
    filters: {
      from: isIsoDate(from) ? from : defaults.from,
      to: isIsoDate(to) ? to : defaults.to,
      company: clipText(q.get('company')),
      user: clipText(q.get('user')),
      outcome: ACT_OUTCOMES.indexOf(outcome) !== -1 ? outcome : ''
    },
    // Up to six digits: far more pages than the log can have, and safe as a number.
    page: page !== null && /^[1-9]\d{0,5}$/.test(page) ? Number(page) : 1
  };
}

// The address-bar URL for the current view; parseActivityParams() reads it back.
function activityPageUrl(filters, page) {
  var q = activityQuery(filters, page);
  return '/monitoring/activity' + (q ? '?' + q : '');
}

// What the Signing activity page shows for a given log status. Anything but
// a readable log would show a wall of zeros, so only the explanation is
// left; a log that has not been written yet still gets its (empty) table.
function activityLayout(status) {
  if (status === 'ok') return { banner: false, tiles: true, filters: true, table: true };
  if (status === 'missing') return { banner: true, tiles: false, filters: true, table: true };
  return { banner: true, tiles: false, filters: false, table: false };
}

function documentLabel(doc) {
  return doc.documentNumber || doc.filename || doc.docid || MON_DASH;
}

// Signature / e-seal / outcome value -> pill.
function resultPill(value) {
  if (value === 'ok') return { cls: 'pill-ok', text: 'OK' };
  if (value === 'completed') return { cls: 'pill-ok', text: 'Completed' };
  if (value === 'failed') return { cls: 'pill-fail', text: 'Failed' };
  if (value === 'skipped') return { cls: 'pill-warn', text: 'Skipped' };
  if (value === 'pending') return { cls: 'pill-muted', text: 'Pending' };
  return { cls: 'pill-muted', text: MON_DASH };
}

var EVENT_LABELS = {
  'document.registered': 'Document registered',
  'signature.visual': 'Visual signature',
  eseal: 'E-seal',
  'signing.finalized': 'Signing finalized',
  'signing.failed': 'Signing failed'
};

function eventLabel(name) {
  return Object.prototype.hasOwnProperty.call(EVENT_LABELS, name) ? EVENT_LABELS[name] : String(name || 'event');
}

function totalPages(total, pageSize) {
  return Math.max(1, Math.ceil((total || 0) / (pageSize || 50)));
}

// ---------------------------------------------------------------------------
// Session expiry and fetching
// ---------------------------------------------------------------------------

var monStopHandlers = [];
var monExpired = false;

// Pages register whatever must stop when the session is gone: poll timers,
// open log streams.
function monOnExpire(fn) {
  monStopHandlers.push(fn);
}

function monExpire() {
  if (monExpired) return;
  monExpired = true;
  var banner = document.getElementById('sessionExpired');
  if (banner) banner.hidden = false;
  monStopHandlers.forEach(function (fn) {
    try { fn(); } catch (err) { /* stopping one thing must not block the rest */ }
  });
}

// fetch() that (a) always sends the session cookie, (b) turns a 401 into the
// "session expired" banner and stops the page's timers/streams, and (c)
// rejects a non-2xx answer with the server's { error } sentence.
function monFetch(url, opts) {
  var options = Object.assign({ credentials: 'same-origin' }, opts || {});
  return fetch(url, options).then(function (resp) {
    if (resp.status === 401) {
      monExpire();
      return Promise.reject({ expired: true, message: 'Your session has expired.' });
    }
    if (resp.ok) return resp.json();
    return resp.json().catch(function () { return {}; }).then(function (body) {
      var err = new Error((body && body.error) || 'The request failed (HTTP ' + resp.status + ').');
      err.status = resp.status;
      throw err;
    });
  }, function () {
    throw new Error('Could not reach the wizard - check your connection.');
  });
}

function monJson(body) {
  return {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body)
  };
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    fmtBytes: fmtBytes,
    fmtDuration: fmtDuration,
    fmtPct: fmtPct,
    fmtTime: fmtTime,
    stateClass: stateClass,
    statePill: statePill,
    healthPill: healthPill,
    alertSeverity: alertSeverity,
    restartImpact: restartImpact,
    classifyLogLine: classifyLogLine,
    logQuery: logQuery,
    logStreamUrl: logStreamUrl,
    logDownloadUrl: logDownloadUrl,
    highlightLine: highlightLine,
    logLineVisible: logLineVisible,
    nearBottom: nearBottom,
    LOG_LINE_CAP: LOG_LINE_CAP,
    activityDefaults: activityDefaults,
    activityQuery: activityQuery,
    csvHref: csvHref,
    parseActivityParams: parseActivityParams,
    activityPageUrl: activityPageUrl,
    activityLayout: activityLayout,
    diffRows: diffRows,
    changedIndexes: changedIndexes,
    documentLabel: documentLabel,
    resultPill: resultPill,
    eventLabel: eventLabel,
    totalPages: totalPages,
    monOnExpire: monOnExpire,
    monFetch: monFetch,
    monJson: monJson
  };
}
