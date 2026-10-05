'use strict';

// A hostname as it may be handed to a script as `--host <value>`, or become
// part of a file name (support-bundle.sh embeds it in the bundle name, and
// NAME_RE only allows [A-Za-z0-9.-] there). Letters, digits, dots and
// hyphens, starting and ending alphanumeric - so no leading '-' that a script
// could mistake for an option, and no separators, whitespace or shell
// metacharacters. This is the lib's own guard: it must hold even for callers
// that skipped route-level validation.
const HOST_RE = /^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$/;

function isValidHost(host) {
  return typeof host === 'string' && HOST_RE.test(host);
}

module.exports = { HOST_RE, isValidHost };
