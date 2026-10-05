'use strict';

const { HOST_PROJECT_DIR } = require('./paths');

// The project root appears in bash's own error text (e.g. "bash: /opt/padsign/
// installation-scripts/x.sh: No such file or directory"). Operators see these
// messages in the browser, so strip the absolute prefix and leave the
// repo-relative path.
const PROJECT_DIR_RE = (() => {
  const dir = String(HOST_PROJECT_DIR || '').replace(/[\\/]+$/, '');
  if (!dir) return null;
  return new RegExp(dir.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '[\\\\/]?', 'g');
})();

function redact(line) {
  return PROJECT_DIR_RE ? line.replace(PROJECT_DIR_RE, '') : line;
}

const lines = (text) => String(text || '')
  .split(/\r?\n/)
  .map((l) => l.trim())
  .filter(Boolean);

// One operator-facing line describing why an execFile() promise rejected.
// Shared by every module that runs a script for the Monitoring section, so
// they all say the same thing and none of them leaks the absolute script
// path or its arguments (Node's own "Command failed: <cmd> <args>" message
// carries both, which is why the message is the last resort and is stripped).
//
// Order: the script's own words first (the last ERROR: line if it printed
// one - a usage error is usually followed by a "usage:" line that would
// otherwise win - else its last stderr line), then what Node knows about the
// process (timeout, exit code), then the message.
function describeExecFailure(err) {
  const e = err || {};

  const stderrLines = lines(e.stderr);
  const lastError = [...stderrLines].reverse().find((l) => l.startsWith('ERROR:'));
  if (lastError) return redact(lastError);
  if (stderrLines.length) return redact(stderrLines[stderrLines.length - 1]);

  if (e.killed || e.signal) return 'timed out';
  if (typeof e.code === 'number') return `exited with code ${e.code}`;

  const messageLines = lines(e.message).filter((l) => !l.startsWith('Command failed:'));
  return redact(messageLines[0] || 'failed to run');
}

// Lines compose prints ahead of the error that stopped it (an unset
// variable, an obsolete `version:` key). They are not the reason it failed.
const COMPOSE_WARNING_RE = /^(WARN\[\d+\]|time="[^"]*" level=warning\b)/;

// A value after a secret-named key, as installation-scripts/lib/redact.py
// names them. Compose quotes the offending value in some errors (an
// interpolation error names the variable and its value), so this runs on
// every line shown. Best effort, like redact.py.
const SECRET_VALUE_RE = /([\w.-]*(?:secret|passw(?:or)?d|pwd|passphrase|api[_-]?key|apikey|token|credential|private[_-]?key|authorization|cookie)[\w.-]*["']?\s*[:=]\s*)("[^"]*"|'[^']*'|\S+)/gi;

function redactSecrets(line) {
  return line.replace(SECRET_VALUE_RE, '$1<redacted>');
}

// One operator-facing line saying why a `docker compose` call failed: the
// first line of its stderr that is not a warning (compose prints the reason
// first, e.g. "stat /srv/overlay/compose.overlay.yml: no such file or
// directory"), with the project path and secret values redacted. Without
// stderr, what Node knows (timeout, exit code, a missing docker binary).
function composeErrorLine(err, max = 300) {
  const e = err || {};
  const stderrLines = lines(e.stderr);
  const reason = stderrLines.find((l) => !COMPOSE_WARNING_RE.test(l)) || stderrLines[0];
  const line = redactSecrets(reason ? redact(reason) : describeExecFailure(e));
  return line.length > max ? `${line.slice(0, max)}…` : line;
}

module.exports = { describeExecFailure, composeErrorLine, redactSecrets };
