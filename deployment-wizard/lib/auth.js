'use strict';

const crypto = require('crypto');

// Single random token generated once per container start, printed to stdout
// (visible via `docker logs`) — Jupyter/Portainer-style first-run unlock.
// No user/password database (decision #7).
const ACCESS_TOKEN = crypto.randomBytes(32).toString('hex');

function getAccessToken() {
  return ACCESS_TOKEN;
}

function timingSafeStringEqual(a, b) {
  const bufA = Buffer.from(String(a));
  const bufB = Buffer.from(String(b));
  if (bufA.length !== bufB.length) {
    // still run a comparison of equal-length buffers so failure timing
    // doesn't leak the real token's length via early return
    crypto.timingSafeEqual(bufA, bufA);
    return false;
  }
  return crypto.timingSafeEqual(bufA, bufB);
}

function checkToken(candidate) {
  if (typeof candidate !== 'string' || candidate.length === 0) return false;
  return timingSafeStringEqual(candidate, ACCESS_TOKEN);
}

// Gate everything except /login and /api/auth behind a valid session.
function requireAuth(req, res, next) {
  if (req.session && req.session.authenticated) {
    return next();
  }
  if (req.path.startsWith('/api/')) {
    return res.status(401).json({ error: 'unauthorized' });
  }
  return res.redirect('/login');
}

module.exports = { getAccessToken, checkToken, requireAuth };
