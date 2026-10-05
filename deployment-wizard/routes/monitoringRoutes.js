'use strict';

const express = require('express');
const { execFile } = require('child_process');
const { promisify } = require('util');

const { ensureWizardSession } = require('../lib/wizardSession');
const { getTopbarContext } = require('../lib/topbarContext');
const { readConfiguredHost, readConfiguredCompanyRole } = require('../lib/dockerFacts');
const { startRun, getRun, isRunActive } = require('../lib/scriptRunner');
const containerFacts = require('../lib/containerFacts');
const logStream = require('../lib/logStream');
const { runMonitorStatus } = require('../lib/monitorStatus');
const diagnostics = require('../lib/diagnostics');
const supportBundle = require('../lib/supportBundle');
const signingActivity = require('../lib/signingActivity');

const DEFAULT_DEPS = {
  readStackServices: containerFacts.readStackServices,
  getOverview: containerFacts.getOverview,
  TAIL_CHOICES: logStream.TAIL_CHOICES,
  validateLogParams: logStream.validateLogParams,
  acquireStream: logStream.acquireStream,
  streamLogsSse: logStream.streamLogsSse,
  streamLogsDownload: logStream.streamLogsDownload,
  runMonitorStatus,
  listChecks: diagnostics.listChecks,
  runCheck: diagnostics.runCheck,
  SINCE_CHOICES: supportBundle.SINCE_CHOICES,
  createBundle: supportBundle.createBundle,
  listBundles: supportBundle.listBundles,
  resolveBundle: supportBundle.resolveBundle,
  isBundleRunning: supportBundle.isBundleRunning,
  getActivity: signingActivity.getActivity,
  getActivityCsv: signingActivity.getActivityCsv,
  startRun,
  getRun,
  isRunActive,
  readConfiguredHost,
  readConfiguredCompanyRole,
  getTopbarContext,
  ensureWizardSession,
  // createBundle() has no default runner on purpose (its tests always inject
  // one), so the real route supplies the promisified execFile.
  exec: promisify(execFile)
};

const TOO_MANY_STREAMS = 'Too many open log streams - close another Logs tab.';

// The sentence an operator sees when `docker compose` itself failed: its own
// reason (already redacted by containerFacts), then the hint when there is one.
function composeFailedMessage(listed) {
  return [`docker compose failed: ${listed.error}`, listed.hint].filter(Boolean).join(' ');
}

// The service the Logs tab opens on: the one asked for in the URL when it is
// really part of the stack, else ps-server (the service operators look at
// first), else whatever comes first, else nothing.
function pickSelectedService(services, requested) {
  if (typeof requested === 'string' && services.includes(requested)) return requested;
  if (services.includes('ps-server')) return 'ps-server';
  return services.length ? services[0] : null;
}

// Error codes createBundle() and its input validation throw, mapped to the
// HTTP status the client acts on: bad input, a bundle already running, or a
// genuine failure.
function bundleErrorStatus(err) {
  const code = err && err.code;
  if (code === 'BAD_SINCE' || code === 'BAD_HOST') return 400;
  if (code === 'BUNDLE_IN_PROGRESS') return 409;
  return 500;
}

// restart-service.sh is started with ['--service', name]; the progress page
// needs the name back, and the run state is the only place it is kept.
function serviceFromRunArgs(args) {
  if (!Array.isArray(args)) return null;
  const i = args.indexOf('--service');
  return i >= 0 && typeof args[i + 1] === 'string' ? args[i + 1] : null;
}

function firstLine(text, max = 300) {
  const line = String(text || '').split(/\r?\n/)[0].trim();
  return line.length > max ? `${line.slice(0, max)}…` : line;
}

function createMonitoringRouter(overrides = {}) {
  const d = { ...DEFAULT_DEPS, ...overrides };
  const router = express.Router();

  // Every JSON answer under /api/monitoring can carry container state, log
  // text or signer e-mail addresses; none of it belongs in a shared cache.
  // (The SSE and download handlers set their own, stricter headers.)
  router.use('/api/monitoring', (req, res, next) => {
    res.setHeader('Cache-Control', 'no-store');
    next();
  });

  // State-changing calls take JSON only (the client sends it through
  // monJson). A cross-site HTML form can only send urlencoded, multipart or
  // text/plain, so this is a second wall behind lib/sameOrigin.js.
  const requireJson = (req, res, next) => (req.is('application/json') ? next() : res.status(415).json({ error: 'Send JSON.' }));

  const unexpected = (res, what, err) => {
    console.error(`Monitoring: ${what} failed:`, err);
    if (res.headersSent) return res.end();
    return res.status(500).json({ error: `${what} failed - check \`docker logs padsign-wizard\`.` });
  };

  async function renderPage(req, res, next, view, tab, extra = {}) {
    try {
      const wizard = d.ensureWizardSession(req);
      const topbar = await d.getTopbarContext(wizard);
      res.render(view, { tab, ...extra, ...topbar });
    } catch (err) {
      next(err);
    }
  }

  // ---- Pages ----

  router.get('/monitoring', (req, res, next) => renderPage(req, res, next, 'monitoring-overview', 'overview'));

  router.get('/monitoring/logs', async (req, res, next) => {
    try {
      const listed = await d.readStackServices();
      const services = listed.services;
      await renderPage(req, res, next, 'monitoring-logs', 'logs', {
        services,
        servicesError: listed.error ? composeFailedMessage(listed) : null,
        selected: pickSelectedService(services, req.query.service),
        TAIL_CHOICES: d.TAIL_CHOICES
      });
    } catch (err) {
      next(err);
    }
  });

  router.get('/monitoring/activity', (req, res, next) => renderPage(req, res, next, 'monitoring-activity', 'activity'));

  router.get('/monitoring/diagnostics', (req, res, next) => renderPage(req, res, next, 'monitoring-diagnostics', 'diagnostics', {
    checks: d.listChecks(),
    bundles: d.listBundles(),
    SINCE_CHOICES: d.SINCE_CHOICES,
    bundleRunning: d.isBundleRunning()
  }));

  router.get('/monitoring/restart-progress', async (req, res, next) => {
    try {
      const runId = String(req.query.runId || '');
      const run = runId ? d.getRun(runId) : null;
      if (!run || run.scriptName !== 'restart-service.sh') return res.redirect('/monitoring');
      const wizard = d.ensureWizardSession(req);
      const topbar = await d.getTopbarContext(wizard);
      res.render('monitoring-restart-progress', {
        runId,
        service: serviceFromRunArgs(run.args) || 'service',
        ...topbar
      });
    } catch (err) {
      next(err);
    }
  });

  // The stack's service names for a request that acts on one of them. When
  // compose fails and no earlier list is cached, answers 503 with compose's
  // reason (instead of a misleading "unknown service") and resolves to null.
  async function servicesOr503(res) {
    const listed = await d.readStackServices();
    if (!listed.services.length && listed.error) {
      res.status(503).json({ error: composeFailedMessage(listed) });
      return null;
    }
    return listed.services;
  }

  // ---- Overview data ----

  router.get('/api/monitoring/services', async (req, res) => {
    try {
      res.json(await d.getOverview());
    } catch (err) {
      unexpected(res, 'Reading the service list', err);
    }
  });

  // monitor-status.sh takes seconds to minutes; a second tab, a Re-run click or
  // an impatient reload must join the run in progress, not start another.
  let statusInFlight = null;
  function runStatusOnce() {
    // Started from a microtask so that even a runner that throws
    // synchronously leaves a settled promise to clear, never a stuck one.
    const run = Promise.resolve().then(() => d.runMonitorStatus({ host: d.readConfiguredHost() || undefined }));
    const clear = () => { statusInFlight = null; };
    run.then(clear, clear);
    return run;
  }

  router.get('/api/monitoring/status', async (req, res) => {
    try {
      if (!statusInFlight) statusInFlight = runStatusOnce();
      res.json(await statusInFlight);
    } catch (err) {
      unexpected(res, 'Reading the status report', err);
    }
  });

  // ---- Logs ----

  router.get('/api/monitoring/logs/stream', async (req, res) => {
    try {
      const services = await servicesOr503(res);
      // The tab may have been closed while the service list was read; do not
      // take a stream slot (or start `docker compose logs -f`) for it.
      if (!services || req.destroyed) return;

      const check = d.validateLogParams(req.query, services);
      if (!check.ok) return res.status(400).json({ error: check.error });

      const release = d.acquireStream(req.sessionID);
      if (!release) return res.status(429).json({ error: TOO_MANY_STREAMS });
      // Either side closing means the tab is gone; release() is idempotent.
      req.on('close', release);
      res.on('close', release);

      const child = d.streamLogsSse(req, res, check.params);
      // null: the client left before anything was spawned, so no 'close'
      // event will fire to free the slot later.
      if (!child) release();
    } catch (err) {
      unexpected(res, 'Opening the log stream', err);
    }
  });

  router.get('/api/monitoring/logs/download', async (req, res) => {
    try {
      const services = await servicesOr503(res);
      if (!services || req.destroyed) return;
      // Following makes no sense for a file: drop it before validating.
      const check = d.validateLogParams({ ...req.query, follow: undefined }, services);
      if (!check.ok) return res.status(400).json({ error: check.error });
      d.streamLogsDownload(res, check.params);
    } catch (err) {
      unexpected(res, 'Downloading the log', err);
    }
  });

  // ---- Restart ----

  router.post('/api/monitoring/restart', requireJson, async (req, res) => {
    try {
      const service = req.body && req.body.service;
      const services = await servicesOr503(res);
      if (!services) return;
      // Only names from the compose service list ever reach the script.
      if (typeof service !== 'string' || !services.includes(service)) {
        return res.status(400).json({ error: 'Unknown service - reload the page and try again.' });
      }
      try {
        const runId = d.startRun({ scriptName: 'restart-service.sh', args: ['--service', service] });
        return res.json({ runId });
      } catch (err) {
        if (err.code === 'RUN_IN_PROGRESS') return res.status(409).json({ error: err.message });
        throw err;
      }
    } catch (err) {
      unexpected(res, 'Starting the restart', err);
    }
  });

  // ---- Diagnostics ----

  router.get('/api/monitoring/diagnostics/:id', async (req, res) => {
    try {
      const result = await d.runCheck(req.params.id, {
        host: d.readConfiguredHost() || undefined,
        companyRole: d.readConfiguredCompanyRole() || undefined
      });
      res.json(result);
    } catch (err) {
      if (err && err.code === 'UNKNOWN_CHECK') return res.status(404).json({ error: 'Unknown check.' });
      unexpected(res, 'Running the check', err);
    }
  });

  // ---- Support bundle ----

  router.post('/api/monitoring/support-bundle', requireJson, async (req, res) => {
    const body = req.body || {};
    try {
      const result = await d.createBundle({
        host: d.readConfiguredHost() || undefined,
        since: body.since === undefined ? undefined : String(body.since),
        exec: d.exec
      });
      res.json(result);
    } catch (err) {
      const status = bundleErrorStatus(err);
      if (status !== 500) return res.status(status).json({ error: err.message });
      console.error('Monitoring: creating the support bundle failed:', err);
      const reason = firstLine(err && err.message);
      res.status(500).json({
        error: `Could not create the support bundle${reason ? `: ${reason}` : ''} - check \`docker logs padsign-wizard\`.`
      });
    }
  });

  router.get('/api/monitoring/support-bundle', (req, res) => {
    try {
      res.json({ bundles: d.listBundles(), running: d.isBundleRunning() });
    } catch (err) {
      unexpected(res, 'Listing support bundles', err);
    }
  });

  router.get('/api/monitoring/support-bundle/:name', (req, res) => {
    let filePath;
    try {
      filePath = d.resolveBundle(req.params.name);
    } catch (err) {
      return unexpected(res, 'Finding the support bundle', err);
    }
    if (!filePath) return res.status(404).json({ error: 'Support bundle not found.' });

    res.setHeader('Cache-Control', 'no-store');
    // cacheControl:false keeps sendFile from replacing the header above.
    res.download(filePath, req.params.name, { cacheControl: false }, (err) => {
      if (!err) return;
      console.error('Monitoring: sending the support bundle failed:', err);
      if (!res.headersSent) res.status(500).json({ error: 'Could not send the support bundle - check `docker logs padsign-wizard`.' });
    });
  });

  // ---- Signing activity ----

  router.get('/api/monitoring/activity', async (req, res) => {
    try {
      res.json(await d.getActivity({ query: req.query }));
    } catch (err) {
      if (err && err.code === 'BAD_RANGE') return res.status(400).json({ error: err.message });
      unexpected(res, 'Reading the signing activity', err);
    }
  });

  router.get('/api/monitoring/activity.csv', async (req, res) => {
    try {
      const { csv, range } = await d.getActivityCsv({ query: req.query });
      res.setHeader('Content-Type', 'text/csv; charset=utf-8');
      res.setHeader('Content-Disposition', `attachment; filename="padsign-signing-activity-${range.from}-${range.to}.csv"`);
      // The byte-order mark makes Excel read the file as UTF-8, so Latvian
      // names keep their diacritics; toCsv() itself stays BOM-free.
      res.send(`﻿${csv}`);
    } catch (err) {
      if (err && err.code === 'BAD_RANGE') return res.status(400).json({ error: err.message });
      unexpected(res, 'Exporting the signing activity', err);
    }
  });

  return router;
}

const router = createMonitoringRouter();

module.exports = router;
module.exports.createMonitoringRouter = createMonitoringRouter;
module.exports.pickSelectedService = pickSelectedService;
module.exports.bundleErrorStatus = bundleErrorStatus;
module.exports.serviceFromRunArgs = serviceFromRunArgs;
module.exports.composeFailedMessage = composeFailedMessage;
