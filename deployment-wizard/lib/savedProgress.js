'use strict';

const fs = require('fs');
const { projectPath } = require('./paths');

const PROGRESS_FILE = projectPath('.wizard-saved-progress.json');

// Persists just enough of the in-progress wizard session to survive
// "Save & Exit" -> logout -> a fresh login, which is a brand-new
// express-session (sessions are in-memory only — decision #8, no
// wizard-side database; this is a small file in the same spirit as the
// existing .wizard-run.lock, not a database).
//
// Deliberately excludes adminPass: a plaintext credential surviving on
// disk across container restarts is a meaningfully bigger exposure than
// today's in-memory-only session value (could end up in a backup/support
// bundle). The operator retypes it on Resume — confirmed with the user.
function saveProgress(wizard, step) {
  const { adminPass, ...rest } = wizard;
  const payload = { ...rest, step, savedAt: new Date().toISOString() };
  fs.writeFileSync(PROGRESS_FILE, JSON.stringify(payload, null, 2), { mode: 0o600 });
}

function loadProgress() {
  try {
    const raw = fs.readFileSync(PROGRESS_FILE, 'utf8');
    return JSON.parse(raw);
  } catch (err) {
    return null;
  }
}

function clearProgress() {
  try {
    fs.unlinkSync(PROGRESS_FILE);
  } catch (err) {
    // already gone — fine
  }
}

function hasSavedProgress() {
  return fs.existsSync(PROGRESS_FILE);
}

module.exports = { saveProgress, loadProgress, clearProgress, hasSavedProgress };
