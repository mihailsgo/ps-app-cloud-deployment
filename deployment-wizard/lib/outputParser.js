'use strict';

// Parses the clean ok()/bad()/warn() convention shared by
// validate-certs.sh and validate-config.sh:
//   "  OK   <msg>" / "  FAIL <msg>" / "  WARN <msg>"
// A bad()/warn() message can itself span multiple physical lines (some
// checks in validate-certs.sh embed a multi-line remediation hint via a
// single printf argument) — continuation lines have no OK/FAIL/WARN
// prefix and are folded into the preceding check's message until a blank
// line or the next prefixed line.
const HELPER_CHECK_RE = /^\s{2,4}(OK|FAIL|WARN)\b\s+(.*)$/;

function parseHelperCheckOutput(stdout) {
  const lines = String(stdout || '').split(/\r?\n/);
  const checks = [];
  let current = null;

  const flush = () => {
    if (current) {
      checks.push(current);
      current = null;
    }
  };

  for (const rawLine of lines) {
    const line = rawLine.replace(/\r$/, '');
    const m = HELPER_CHECK_RE.exec(line);
    if (m) {
      flush();
      current = { status: m[1].toLowerCase(), message: m[2].trim() };
    } else if (current && line.trim() !== '') {
      current.message += '\n' + line.trim();
    } else {
      flush();
    }
  }
  flush();

  const passed = checks.every((c) => c.status !== 'fail');
  return { passed, checks, raw: String(stdout || '') };
}

// ---- Streaming classifier for bootstrap.sh / upgrade.sh live output ----
//
// Unlike validate-certs.sh/validate-config.sh (clean ok()/bad()/warn()
// helpers above), bootstrap.sh and upgrade.sh use two DIFFERENT ad hoc
// conventions of their own, plus scattered WARNING:/ERROR: lines. Every
// pattern below was matched against the actual scripts, not guessed:
//   - "Step 1/8: Backing up config files..."      (bootstrap.sh, upgrade.sh)
//   - "Step 4b/6: Enabling local e-sealing..."     (upgrade.sh — letter suffix)
//   - "  ps-server: OK"                             (ad hoc colon-suffix check)
//   - "  Root redirect: OK (301 -> /portal/)"       (ad hoc colon-suffix check)
//   - "  WARNING: ps-server may not have started..." (non-fatal, to stderr)
//   - "ERROR: Missing dependency: docker"           (fatal, to stderr)
// Order matters: STEP_RE and COLON_CHECK_RE are checked before the looser
// WARNING_RE, since a WARNING line's own leading text could otherwise
// partially resemble a colon-check.
const STEP_RE = /^Step (\d+[a-z]?)\/(\d+):\s*(.*)$/;
const COLON_CHECK_RE = /^\s{2}([^:]+):\s*(OK|WARNING)\b(.*)$/;
const WARNING_RE = /^\s*WARNING:\s*(.*)$/;
const ERROR_RE = /^\s*ERROR:\s*(.*)$/;

function stripAnsi(line) {
  // eslint-disable-next-line no-control-regex
  return line.replace(/\x1b\[[0-9;]*m/g, '');
}

function parseLine(rawLine) {
  const line = stripAnsi(String(rawLine || '')).replace(/\r$/, '');
  let m;
  if ((m = STEP_RE.exec(line))) {
    return { type: 'step', step: m[1], total: Number(m[2]), label: m[3].trim() };
  }
  if ((m = COLON_CHECK_RE.exec(line))) {
    return { type: 'check', status: m[2] === 'OK' ? 'ok' : 'warn', label: `${m[1].trim()}${m[3]}`.trim() };
  }
  if ((m = WARNING_RE.exec(line))) {
    return { type: 'warning', message: m[1] };
  }
  if ((m = ERROR_RE.exec(line))) {
    return { type: 'error', message: m[1] };
  }
  return { type: 'raw', line };
}

module.exports = { parseHelperCheckOutput, parseLine, HELPER_CHECK_RE };
