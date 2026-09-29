'use strict';

const { execFile } = require('child_process');
const { promisify } = require('util');
const execFileP = promisify(execFile);

const { HOST_PROJECT_DIR, projectPath } = require('./paths');
const { validateConfig } = require('./configValidator');
const { checkLiveCert, checkServedCert } = require('./certValidator');
const { runMonitorStatus, alertSeverity } = require('./monitorStatus');
const { parseHelperCheckOutput } = require('./outputParser');
const { describeExecFailure } = require('./execError');

const VERIFY_KEYCLOAK_SCRIPT = projectPath('installation-scripts', 'verify-keycloak.sh');

// verify-keycloak.sh's own convention: no leading indent at all (unlike
// validate-certs.sh / validate-config.sh's 2-4 space indent), plus a closing
// "RESULT: ..." line that summarizes the run and is not itself a check.
// Widening the indent range to 0-4 spaces covers both conventions, and the
// RESULT: line is skipped (ending the current check) rather than folded into
// the previous check's message.
const LOOSE_CHECK_RE = /^\s{0,4}(OK|FAIL|WARN)\b\s+(.*)$/;

function parseLooseCheckOutput(stdout) {
  return parseHelperCheckOutput(stdout, {
    re: LOOSE_CHECK_RE,
    skip: (line) => line.trim().startsWith('RESULT:')
  });
}

// Turns monitor-status.sh's alerts[] into the same {status,message} check
// rows every other diagnostics card already uses, so "Alert thresholds" can
// render with the identical card UI as config/cert/keycloak.
function alertsToChecks(report) {
  const alerts = (report && report.alerts) || [];
  if (alerts.length === 0) {
    return [{ status: 'ok', message: 'No alert thresholds are crossed.' }];
  }
  return alerts.map((a) => ({ status: alertSeverity(a.key), message: `${a.key}: ${a.message}` }));
}

// Order here is display order in the Diagnostics tab.
const CHECKS = [
  {
    id: 'config',
    label: 'Configuration',
    description: 'Runs validate-config.sh: syntax and consistency of every configuration file.'
  },
  {
    id: 'cert',
    label: 'Deployed certificate',
    description: 'Runs validate-certs.sh against the certificate currently deployed to nginx/certs/.'
  },
  {
    id: 'served-cert',
    label: 'Certificate nginx is serving',
    description: 'Runs verify-served-cert.sh: opens a TLS handshake and compares what nginx serves to the certificate on disk.'
  },
  {
    id: 'keycloak',
    label: 'Keycloak realm and clients',
    description: 'Runs verify-keycloak.sh: confirms the padsign realm, clients, roles and demo user are configured as expected.'
  },
  {
    id: 'alerts',
    label: 'Alert thresholds',
    description: 'Runs monitor-status.sh and reports any alert thresholds currently crossed.'
  }
];

// cert/served-cert/keycloak all need a configured hostname to mean anything;
// config and alerts degrade gracefully (validate-config.sh and
// monitor-status.sh both accept a missing --host) so they are left out.
const NEEDS_HOST = new Set(['cert', 'served-cert', 'keycloak']);

function listChecks() {
  return CHECKS.map(({ id, label, description }) => ({ id, label, description }));
}

// Runs one named check and always resolves to a renderable card — the only
// rejection a caller needs to handle is an unknown id (a programming error,
// e.g. a stale route), never a runner failure. `deps` lets tests substitute
// every real dependency without touching the module's own bash/exec wiring.
async function runCheck(id, { host, companyRole, deps = {} } = {}) {
  const def = CHECKS.find((c) => c.id === id);
  if (!def) {
    const err = new Error(`Unknown diagnostics check: ${id}`);
    err.code = 'UNKNOWN_CHECK';
    throw err;
  }

  const {
    validateConfig: validateConfigDep = validateConfig,
    checkLiveCert: checkLiveCertDep = checkLiveCert,
    checkServedCert: checkServedCertDep = checkServedCert,
    runMonitorStatus: runMonitorStatusDep = runMonitorStatus,
    exec: execDep = execFileP
  } = deps;

  const startedAt = Date.now();
  const finish = (rawChecks) => {
    // A script that exits 1 having printed only to stderr parses to zero
    // rows, and zero FAILs would otherwise read as a green "passed" card.
    // "Ran but told us nothing" is a warning, never a pass.
    const checks = rawChecks && rawChecks.length
      ? rawChecks
      : [{ status: 'warn', message: `${def.label} produced no results.` }];
    return {
      id: def.id,
      label: def.label,
      // A warn-only result still counts as passed — only a FAIL should flip
      // the card red. Diagnostics deliberately drops `raw` (present on
      // configValidator/certValidator's own return shape): it can be large
      // and nothing downstream of runCheck() needs the untrimmed script output.
      passed: checks.every((c) => c.status !== 'fail'),
      checks,
      durationMs: Date.now() - startedAt
    };
  };
  const noHost = () => finish([{ status: 'warn', message: 'No hostname is configured yet.' }]);

  try {
    if (NEEDS_HOST.has(id) && !host) return noHost();

    if (id === 'config') {
      const result = await validateConfigDep({ host });
      return finish(result.checks);
    }

    if (id === 'cert') {
      const result = await checkLiveCertDep(host);
      return finish(result.checks);
    }

    if (id === 'served-cert') {
      const result = await checkServedCertDep(host);
      return finish(result.checks);
    }

    if (id === 'keycloak') {
      if (!companyRole || companyRole === 'CHANGE_ME') {
        return finish([{
          status: 'warn',
          message: 'The company role is not configured (DEMO_COMPANY_ROLE in config/config.js).'
        }]);
      }

      let stdout;
      try {
        const result = await execDep(
          'bash',
          [VERIFY_KEYCLOAK_SCRIPT, '--host', host, '--company-role', companyRole],
          { cwd: HOST_PROJECT_DIR, timeout: 120000, maxBuffer: 4 * 1024 * 1024 }
        );
        stdout = result.stdout;
      } catch (err) {
        // exit 1 = "some checks FAILED" — expected outcome, same convention
        // validate-config.sh/validate-certs.sh already use. Anything else
        // (usage error, timeout, missing script) falls through to the
        // generic "runner threw" handling below.
        if (typeof err.code === 'number' && err.code === 1 && typeof err.stdout === 'string') {
          stdout = err.stdout;
        } else {
          throw err;
        }
      }
      return finish(parseLooseCheckOutput(stdout).checks);
    }

    // id === 'alerts'
    const result = await runMonitorStatusDep({ host });
    if (!result.ok) {
      return finish([{ status: 'warn', message: result.error }]);
    }
    return finish(alertsToChecks(result.report));
  } catch (err) {
    // Never reject for a known id — a broken runner degrades to a single
    // warn row so the Diagnostics tab can always render a card.
    return finish([{ status: 'warn', message: `${def.label} could not be run: ${describeExecFailure(err)}` }]);
  }
}

module.exports = { CHECKS, listChecks, runCheck, parseLooseCheckOutput, alertsToChecks };
