#!/usr/bin/env bash
set -euo pipefail
# Used by scriptRunner.test.js: reports what the child received, never the value.
echo "argc=$#"
echo "env=${KEYCLOAK_ADMIN_PASSWORD:+set}"
exit 0
