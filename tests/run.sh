#!/bin/bash
# Runs every helper test against fixture repos in a temp HOME. No shell, no
# QML, no network; gh and herdr are stubs from tests/stubs.
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
rc=0
for t in config state watch action remote herdr; do
  bash "$ROOT/$t-test.sh" || rc=1
done
exit $rc
