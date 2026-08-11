#!/usr/bin/env bash
set -euo pipefail
echo "Step 1/3: doing thing one"
echo "  sub-check one: OK"
echo "Step 2/3: doing thing two"
echo "  WARNING: something minor" >&2
echo "Step 3/3: doing thing three"
echo "  final-check: OK"
exit 0
