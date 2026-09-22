#!/usr/bin/env bash
# validate.sh — run README.md as a test.
#
# mechanical-markdown (the tool Dapr's quickstarts use) executes the bash blocks inside
# <!-- STEP --> annotations and checks their output against what the README claims. So
# the tutorial and the test are the same file, and a README that has drifted from
# reality fails.
#
# Exit codes are the point of this wrapper:
#
#   0  the README ran and every expectation held
#   1  the README ran and something did not match  — a real failure
#   2  the README could not be run at all          — missing tool, no Floci
#
# mm.py only knows 0 and 1. Without the 2, a missing Floci would surface as "nothing ran,
# nothing failed", and a skip that reports success is worse than a failure: it is the one
# result you will believe without checking.
set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENDPOINT="${AWS_ENDPOINT_URL:-http://localhost:4566}"

cannot_run() { printf '\033[1;33mCANNOT RUN: %s\033[0m\n' "$*" >&2; exit 2; }

for tool in docker node npm aws jq python3; do
  command -v "$tool" >/dev/null || cannot_run "$tool is not installed"
done

command -v mm.py >/dev/null || cannot_run \
  "mechanical-markdown is not installed. Try:
     python3 -m venv .venv && . .venv/bin/activate && pip install -r requirements.txt"

curl -fsS -m 5 "$ENDPOINT/_floci/health" >/dev/null 2>&1 || cannot_run \
  "Floci is not answering at $ENDPOINT. Start it with: docker compose up -d"

echo "Floci $(curl -fsS "$ENDPOINT/_floci/health" | jq -r .version) at $ENDPOINT"
echo "Running README.md as a test..."
echo

mm.py README.md
status=$?

# Anything mm.py did not report as a clean pass is a failure, including a signal.
[ "$status" -eq 0 ] || exit 1
echo
echo "README.md passed."
