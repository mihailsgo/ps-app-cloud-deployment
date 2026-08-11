'use strict';

const express = require('express');
const { checkToken } = require('../lib/auth');

const router = express.Router();

router.get('/login', (req, res) => {
  if (req.session && req.session.authenticated) {
    return res.redirect('/');
  }
  res.render('login', { error: null });
});

router.post('/api/auth', express.urlencoded({ extended: false }), (req, res) => {
  const { token } = req.body || {};
  if (checkToken(token)) {
    req.session.authenticated = true;
    return res.redirect('/');
  }
  res.status(401).render('login', { error: 'Invalid token. Check `docker logs padsign-wizard` for the current value.' });
});

router.post('/api/logout', (req, res) => {
  req.session.destroy(() => res.redirect('/login'));
});

module.exports = router;
