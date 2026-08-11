'use strict';

const fs = require('fs');
const { execFile } = require('child_process');
const { promisify } = require('util');
const execFileP = promisify(execFile);

const { HOST_PROJECT_DIR, projectPath } = require('./paths');

// Everything here is read-only introspection of the host's Docker state via
// the mounted socket — no mutation. Kept separate from scriptRunner.js,
// which is the only module allowed to spawn bootstrap.sh/upgrade.sh.

// Returns [] if docker/compose isn't reachable or the project has never
// been brought up — never throws, since this is called on every page load
// (decision #8: no wizard-side database, state is derived live).
async function listComposeServices() {
  try {
    const { stdout } = await execFileP(
      'docker',
      ['compose', 'ps', '--format', 'json', '--all'],
      { cwd: HOST_PROJECT_DIR, timeout: 10000 }
    );
    return parseComposePsOutput(stdout);
  } catch (err) {
    return [];
  }
}

// `docker compose ps --format json` output varies by Compose version:
// some emit a single JSON array, others emit newline-delimited JSON
// objects (ndjson) — handle both rather than assuming one.
function parseComposePsOutput(stdout) {
  const trimmed = (stdout || '').trim();
  if (!trimmed) return [];
  try {
    const parsed = JSON.parse(trimmed);
    return Array.isArray(parsed) ? parsed : [parsed];
  } catch (err) {
    return trimmed
      .split('\n')
      .map((line) => line.trim())
      .filter(Boolean)
      .map((line) => {
        try {
          return JSON.parse(line);
        } catch (innerErr) {
          return null;
        }
      })
      .filter(Boolean);
  }
}

async function dockerAvailable() {
  try {
    await execFileP('docker', ['version', '--format', '{{.Server.Version}}'], { timeout: 5000 });
    return true;
  } catch (err) {
    return false;
  }
}

// Same extraction validate-config.sh already does
// (`grep -oP 'mihailsgordijenko/ps-server:\K[0-9.]+'`) — read directly in
// Node rather than shelling out, so the dashboard's "current version" line
// can never disagree with what validate-config.sh reports, without
// depending on grep -P support (missing on Alpine's BusyBox grep).
function readImageTags() {
  let content = '';
  try {
    content = fs.readFileSync(projectPath('docker-compose.yml'), 'utf8');
  } catch (err) {
    return { serverTag: null, clientTag: null };
  }
  const serverMatch = content.match(/mihailsgordijenko\/ps-server:([0-9.]+)/);
  const clientMatch = content.match(/mihailsgordijenko\/ps-client:([0-9.]+)/);
  return {
    serverTag: serverMatch ? serverMatch[1] : null,
    clientTag: clientMatch ? clientMatch[1] : null
  };
}

// "What's the latest release this repo checkout knows about" — for the
// Dashboard's 3-state Upgrade panel (nav/UX pass). Reads
// documentation/01-release-snapshot.md, the same single source of truth
// validate-config.sh's own release-snapshot consistency check already
// treats as authoritative, using the identical extraction pattern as
// readImageTags() above. Returns nulls (never throws) if the file is
// missing or doesn't match — the dashboard treats that as "can't tell,
// show the custom-tag state" rather than a hard error.
function readLatestKnownTags() {
  let content = '';
  try {
    content = fs.readFileSync(projectPath('documentation', '01-release-snapshot.md'), 'utf8');
  } catch (err) {
    return { serverTag: null, clientTag: null };
  }
  const serverMatch = content.match(/mihailsgordijenko\/ps-server:([0-9.]+)/);
  const clientMatch = content.match(/mihailsgordijenko\/ps-client:([0-9.]+)/);
  return {
    serverTag: serverMatch ? serverMatch[1] : null,
    clientTag: clientMatch ? clientMatch[1] : null
  };
}

// Best-effort "what hostname is this checkout currently configured for" —
// used so the dashboard works even when the wizard's own session has no
// memory of a prior onboarding run (decision #8: derive from live files,
// never from session state alone).
function readConfiguredHost() {
  let content = '';
  try {
    content = fs.readFileSync(projectPath('nginx', 'nginx.conf'), 'utf8');
  } catch (err) {
    return null;
  }
  const match = content.match(/server_name\s+([^\s;]+);/);
  return match ? match[1] : null;
}

// Live-read the current on/off state of the 3 feature flags (Settings
// feature) — never throws; a field is `null` only when its source file
// couldn't be read/parsed at all, never as a guess. `localEseal` is the one
// exception: if config.js is readable but has no STAMP_MODE field yet
// (never provisioned), that's definitively "false", not "unknown".
function readConfiguredFeatures() {
  let routing = null;
  let localEseal = null;
  try {
    const configJs = fs.readFileSync(projectPath('config', 'config.js'), 'utf8');
    // Mirrors the exact "find DOCUMENT_ROUTING, then the next `enabled:`
    // line" state machine configure-host.sh's --enable-routing/
    // --disable-routing perl one-liners use, so this can never disagree
    // with what those flags actually set (the master switch only — a
    // per-strategy `enabled:` further down is deliberately not matched).
    const drIndex = configJs.indexOf('DOCUMENT_ROUTING');
    if (drIndex !== -1) {
      const afterDr = configJs.slice(drIndex);
      const m = afterDr.match(/enabled:\s*(true|false)/);
      routing = m ? m[1] === 'true' : null;
    }
    const stampMatch = configJs.match(/STAMP_MODE:\s*"([a-z]+)"/);
    localEseal = stampMatch ? stampMatch[1] === 'local' : false;
  } catch (err) {
    // config.js unreadable — routing/localEseal stay null (can't tell)
  }

  let demo = null;
  try {
    const constants = JSON.parse(fs.readFileSync(projectPath('config', 'constants.json'), 'utf8'));
    demo = typeof constants.DEMO_MODE === 'string' ? constants.DEMO_MODE.toUpperCase() === 'ENABLE' : null;
  } catch (err) {
    // constants.json missing/invalid JSON — demo stays null
  }

  let localEsealProfileActive = false;
  try {
    const env = fs.readFileSync(projectPath('.env'), 'utf8');
    const profilesMatch = env.match(/^COMPOSE_PROFILES=(.*)$/m);
    localEsealProfileActive = profilesMatch
      ? profilesMatch[1].split(',').map((s) => s.trim()).includes('local-eseal')
      : false;
  } catch (err) {
    // no .env — profile is definitively inactive (that's the default)
  }

  // Deliberately no "localEsealProvisioned" field: an earlier version of
  // this function checked docker-compose.yml for the
  // dmss-digital-stamping-service block, meant to distinguish "never
  // provisioned" from "provisioned but off". That check was always true —
  // the compose block (and the demo seal.p12/application.yml under
  // dmss-digital-stamping-service/) ship pre-committed in every checkout of
  // this repo, not inserted on first --enable-local-eseal like this
  // function assumed. Found via a live E2E test of the Settings feature
  // (the "(not yet provisioned)" hint it drove could never render). The
  // genuinely lazy signal is `localEseal` itself (STAMP_MODE's presence in
  // config.js, which really is absent until first enabled).
  return { routing, demo, localEseal, localEsealProfileActive };
}

// Live-read the company/role name a hostname change must pass through
// unchanged to keycloak-bootstrap.sh (update-hostname.sh does this exact
// read itself in bash, independently — this copy exists only so the
// Settings page can display the current value, not to feed the script).
function readConfiguredCompanyRole() {
  try {
    const configJs = fs.readFileSync(projectPath('config', 'config.js'), 'utf8');
    const m = configJs.match(/DEMO_COMPANY_ROLE:\s*"([^"]*)"/);
    return m ? m[1] : null;
  } catch (err) {
    return null;
  }
}

module.exports = {
  listComposeServices,
  dockerAvailable,
  readImageTags,
  readLatestKnownTags,
  readConfiguredHost,
  readConfiguredFeatures,
  readConfiguredCompanyRole
};
