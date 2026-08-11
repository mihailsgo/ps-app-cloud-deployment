'use strict';

const { execFile } = require('child_process');
const { promisify } = require('util');

const { HOST_PROJECT_DIR, projectPath } = require('./paths');

const execFileP = promisify(execFile);
const UPGRADE_SCRIPT = projectPath('installation-scripts', 'upgrade.sh');

// Reads the plan `upgrade.sh --plan-only` produces. Deliberately uses
// execFile directly rather than lib/scriptRunner.js: scriptRunner takes a
// single global run lock (one script at a time, topbar nav disabled while
// held), which is right for a mutating run and wrong for a read-only preview.
// Same reasoning and same option shape as lib/configValidator.js.

const MARKERS = {
  begin: '###PLAN-BEGIN',
  end: '###PLAN-END',
  item: '###PLAN-ITEM',
  itemEnd: '###PLAN-ITEM-END',
  bodyBegin: '###PLAN-BODY-BEGIN',
  bodyEnd: '###PLAN-BODY-END'
};

// Line-delimited rather than JSON because the bodies are literal config
// fragments full of quotes, braces and slashes, and hand-rolling JSON
// escaping in bash is a foot-gun. Anything outside the markers is ignored,
// so stray script output can't corrupt the parse.
function parsePlan(stdout) {
  const lines = String(stdout).split(/\r?\n/);
  const header = {};
  const items = [];

  let inPlan = false;
  let item = null;
  let bodyLines = null;

  for (const line of lines) {
    if (line === MARKERS.begin) { inPlan = true; continue; }
    if (!inPlan) continue;
    if (line === MARKERS.end) break;

    if (bodyLines) {
      if (line === MARKERS.bodyEnd) {
        item.body = bodyLines.join('\n').replace(/\s+$/, '');
        bodyLines = null;
      } else {
        bodyLines.push(line);
      }
      continue;
    }

    if (line === MARKERS.item) { item = { id: '', status: '', files: [], title: '', body: '' }; continue; }
    if (line === MARKERS.itemEnd) { if (item && item.id) items.push(item); item = null; continue; }
    if (line === MARKERS.bodyBegin) { bodyLines = []; continue; }

    const eq = line.indexOf('=');
    if (eq === -1) continue;
    const key = line.slice(0, eq);
    const value = line.slice(eq + 1);

    if (item) {
      if (key === 'files') item.files = value.split(',').map((f) => f.trim()).filter(Boolean);
      else if (key in item) item[key] = value;
    } else {
      header[key] = value;
    }
  }

  const tags = {
    server: { from: header.server_tag_from || null, to: header.server_tag_to || null },
    client: { from: header.client_tag_from || null, to: header.client_tag_to || null }
  };
  tags.server.changes = Boolean(tags.server.from && tags.server.to && tags.server.from !== tags.server.to);
  tags.client.changes = Boolean(tags.client.from && tags.client.to && tags.client.from !== tags.client.to);

  const pending = items.filter((i) => i.status === 'will-apply');

  return {
    tags,
    items,
    pendingCount: pending.length,
    // "Nothing to review" is the common case on a routine bump, and the view
    // renders it differently — worth stating explicitly rather than making
    // every caller re-derive it.
    empty: pending.length === 0
  };
}

async function getUpgradePlan(args) {
  let stdout;
  try {
    const result = await execFileP('bash', [UPGRADE_SCRIPT, ...args, '--plan-only', '--plan-format', 'machine'], {
      cwd: HOST_PROJECT_DIR,
      timeout: 30000,
      maxBuffer: 4 * 1024 * 1024
    });
    stdout = result.stdout;
  } catch (err) {
    // upgrade.sh exits 2 for a rejected argument combination (e.g. the
    // local-eseal minimum-tag gate). That is a real answer for the operator,
    // not a wizard fault — surface its stderr rather than a generic 500.
    if (typeof err.code === 'number' && err.code === 2) {
      const message = String(err.stderr || '').split('\n').filter(Boolean)[0]
        || 'upgrade.sh rejected these options.';
      const refusal = new Error(message);
      refusal.code = 'PLAN_REFUSED';
      refusal.detail = String(err.stderr || '');
      throw refusal;
    }
    throw err;
  }

  const plan = parsePlan(stdout);
  plan.raw = stdout;
  return plan;
}

module.exports = { getUpgradePlan, parsePlan };
