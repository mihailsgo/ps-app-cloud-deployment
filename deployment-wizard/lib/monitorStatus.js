'use strict';

const { execFile } = require('child_process');
const { promisify } = require('util');
const execFileP = promisify(execFile);

const { HOST_PROJECT_DIR, projectPath } = require('./paths');

const MONITOR_STATUS_SCRIPT = projectPath('installation-scripts', 'monitor-status.sh');

// Alerts that mean something is actually down right now vs. everything else
// (a threshold crossed, a warning worth a look). Kept as one lookup so the
// Overview cards and the Diagnostics "Alert thresholds" check can never
// disagree about how loud an alert should be.
const FAIL_ALERT_KEYS = new Set(['service_down', 'service_unhealthy']);

function alertSeverity(key) {
  return FAIL_ALERT_KEYS.has(key) ? 'fail' : 'warn';
}

// Picks the clearest single line to show an operator out of a failed exec():
// an explicit stderr line (monitor-status.sh's own usage errors go to
// stderr), falling back to the Error's own message (a Node-level failure
// such as ENOENT or a timeout never populates stderr at all).
function describeExecFailure(err) {
  const stderrLines = String((err && err.stderr) || '')
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter(Boolean);
  if (stderrLines.length) return stderrLines[0];
  return (err && err.message) || 'monitor-status.sh could not be run';
}

// Runs monitor-status.sh --format json and parses its single JSON document.
// Never throws: every failure mode (an older checkout without --format
// support, a timeout, the script missing entirely, or output that isn't the
// expected schema) resolves to { ok:false, error } so the Monitoring
// Overview can render one degraded alert card instead of a 500.
//
// `exec` is injectable (defaults to execFile, promisified) because this
// module is written ahead of installation-scripts/monitor-status.sh, which a
// parallel task is still authoring — every test supplies its own `exec`.
async function runMonitorStatus({ host, exec = execFileP } = {}) {
  const args = [MONITOR_STATUS_SCRIPT, '--format', 'json', ...(host ? ['--host', host] : [])];

  let stdout;
  try {
    const result = await exec('bash', args, {
      cwd: HOST_PROJECT_DIR,
      timeout: 90000,
      maxBuffer: 8 * 1024 * 1024
    });
    stdout = result.stdout;
  } catch (err) {
    return { ok: false, error: `monitor-status.sh could not be run: ${describeExecFailure(err)}` };
  }

  let report;
  try {
    report = JSON.parse(stdout);
  } catch (err) {
    return { ok: false, error: 'monitor-status.sh returned an unexpected format' };
  }

  if (!report || report.schema !== 1) {
    return { ok: false, error: 'monitor-status.sh returned an unexpected format' };
  }

  return { ok: true, report };
}

module.exports = { runMonitorStatus, alertSeverity };
