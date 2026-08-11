'use strict';

const path = require('path');
const express = require('express');
const session = require('express-session');

const defaults = require('./config/defaults');
const { requireAuth } = require('./lib/auth');
const authRoutes = require('./routes/auth');
const wizardStepsRoutes = require('./routes/wizardSteps');
const certRoutes = require('./routes/certRoutes');
const deployRoutes = require('./routes/deploy');
const dashboardRoutes = require('./routes/dashboard');
const upgradeRoutes = require('./routes/upgradeRoutes');
const settingsRoutes = require('./routes/settingsRoutes');

function createApp() {
  const app = express();

  app.set('view engine', 'ejs');
  app.set('views', path.join(__dirname, 'views'));
  app.use(express.static(path.join(__dirname, 'public')));
  app.use(express.urlencoded({ extended: false }));
  app.use(express.json());

  // In-memory session store (default) — deliberate: no wizard-side database
  // (decision #8). This session doubles as both the auth gate and, from
  // Phase B onward, the in-progress wizard-form store (decision #13).
  app.use(
    session({
      name: 'padsign_wizard_sid',
      secret: require('crypto').randomBytes(32).toString('hex'), // rotates every restart — fine, sessions aren't meant to survive one
      resave: false,
      saveUninitialized: false,
      cookie: {
        httpOnly: true,
        secure: true,
        sameSite: 'strict',
        maxAge: defaults.sessionTtlMs
      }
    })
  );

  // Everything except /login and /api/auth requires a valid session.
  app.use((req, res, next) => {
    if (req.path === '/login' || req.path === '/api/auth') return next();
    return requireAuth(req, res, next);
  });

  // Which topbar section is current, derived from the path so no route has
  // to remember to pass it. Consumed by views/partials/topbar.ejs to render
  // aria-current="page" — previously Dashboard and Settings were two
  // identical pills with nothing indicating where you were.
  app.use((req, res, next) => {
    const p = req.path;
    res.locals.activeNav =
      p === '/dashboard' || p.startsWith('/upgrade') ? 'dashboard'
        : p.startsWith('/settings') ? 'settings'
          : p === '/' || p.startsWith('/wizard') ? 'setup'
            : '';
    next();
  });

  app.use(authRoutes);
  app.use(certRoutes);
  app.use(deployRoutes);
  app.use(dashboardRoutes);
  app.use(upgradeRoutes);
  app.use(settingsRoutes);
  app.use(wizardStepsRoutes);

  app.use((err, req, res, next) => {
    console.error(err);
    res.status(500).send('Internal error — check `docker logs padsign-wizard` for details.');
  });

  return app;
}

module.exports = { createApp };
