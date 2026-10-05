'use strict';

/*
 * Refuses state-changing requests that a browser reports as coming from
 * another site or origin.
 *
 * The session cookie is SameSite=Strict, but that only blocks cross-SITE
 * requests. The wizard (:8443) is same-SITE with the PadSign portal (:443)
 * and Keycloak on the same host, so a script served there could still submit
 * a form to the wizard with the operator's cookie attached. Browsers label
 * every request, so we use the labels:
 *
 *   - Sec-Fetch-Site (all current browsers): anything but same-origin (or
 *     none, a typed URL / bookmark) is refused. It cannot be set by page
 *     script, and when it is present it is authoritative, so the Origin
 *     comparison below is skipped (a reverse proxy that rewrites Host must
 *     not lock operators out).
 *   - Origin, for a browser that does not send Sec-Fetch-Site: its host must
 *     equal the Host the request was addressed to. "Origin: null" is refused.
 *
 * A request with neither header (curl, scripts, tests) is not a browser
 * acting on someone's behalf and passes; it has no cookie to ride on.
 */

const SAFE_METHODS = new Set(['GET', 'HEAD', 'OPTIONS']);
const REFUSAL = 'Cross-site request refused.';

function refuse(res) {
  return res.status(403).json({ error: REFUSAL });
}

function originHost(origin) {
  try {
    return new URL(origin).host;
  } catch (err) {
    return null;
  }
}

// Pure decision, separate from Express so it can be tested on plain values:
// true when the request may proceed.
function isCrossSiteRequestAllowed({ method, secFetchSite, origin, host }) {
  if (SAFE_METHODS.has(String(method).toUpperCase())) return true;
  if (secFetchSite !== undefined) return secFetchSite === 'same-origin' || secFetchSite === 'none';
  if (origin !== undefined) {
    const h = originHost(origin);
    return h !== null && h === host;
  }
  return true;
}

function refuseCrossSite(req, res, next) {
  const allowed = isCrossSiteRequestAllowed({
    method: req.method,
    secFetchSite: req.get('Sec-Fetch-Site'),
    origin: req.get('Origin'),
    host: req.get('Host')
  });
  return allowed ? next() : refuse(res);
}

module.exports = { refuseCrossSite, isCrossSiteRequestAllowed, REFUSAL };
