'use strict';

const path = require('path');

// Single source of truth for the project root, as seen by BOTH this
// container's filesystem and the host Docker daemon (via the mounted
// socket). Must be bind-mounted at the identical absolute path on both
// sides (see docker-compose.yml `wizard` service: `${PWD}:${PWD}`,
// `working_dir: ${PWD}`) — otherwise `docker compose` commands this
// process spawns would resolve their relative bind mounts against a path
// the host daemon has never heard of.
const HOST_PROJECT_DIR = process.env.HOST_PROJECT_DIR || process.cwd();

function projectPath(...segments) {
  return path.join(HOST_PROJECT_DIR, ...segments);
}

module.exports = { HOST_PROJECT_DIR, projectPath };
