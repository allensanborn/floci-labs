#!/usr/bin/env bash
# teardown.sh — stop lean-cloud's nodes and remove what the lab wrote to Floci.
# infra.sh destroys its own AWS stack; this cleans up after run.sh.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AWS_ENDPOINT_URL=${AWS_ENDPOINT_URL:-http://localhost:4566} AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:-test} \
  AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:-test} AWS_DEFAULT_REGION=us-east-1 AWS_PAGER=
docker compose -f nodes.compose.yaml --progress quiet down -v
for bucket in lean-cloud-lab lean-cloud-integration lean-cloud-storage-tests; do
  aws s3 rb "s3://$bucket" --force >/dev/null 2>&1 && echo "removed s3://$bucket"
done
echo "teardown complete"
