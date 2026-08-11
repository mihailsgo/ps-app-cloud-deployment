'use strict';

const { execFile } = require('child_process');
const { promisify } = require('util');
const execFileP = promisify(execFile);

const { HOST_PROJECT_DIR, projectPath } = require('./paths');
const { parseHelperCheckOutput } = require('./outputParser');

const VALIDATE_CONFIG_SCRIPT = projectPath('installation-scripts', 'validate-config.sh');

// Used by step 7 (Verify) and, from Phase D onward, the dashboard.
// Read-only — never mutates anything, matches validate-config.sh itself.
async function validateConfig({ host } = {}) {
  const args = host ? ['--host', host] : [];
  let stdout;
  try {
    const result = await execFileP('bash', [VALIDATE_CONFIG_SCRIPT, ...args], {
      cwd: HOST_PROJECT_DIR,
      timeout: 30000,
      maxBuffer: 4 * 1024 * 1024
    });
    stdout = result.stdout;
  } catch (err) {
    // exit 1 = "some checks FAILED" — expected outcome, not a wizard bug.
    if (typeof err.code === 'number' && err.code === 1 && typeof err.stdout === 'string') {
      stdout = err.stdout;
    } else {
      throw err;
    }
  }
  return parseHelperCheckOutput(stdout);
}

module.exports = { validateConfig };
