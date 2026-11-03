#!/usr/bin/env bash
# run.sh — lean-cloud's runtime with Floci as its S3 blob store.
#
#   1. the repo's storage contract test     (cloud_storage_tests)
#   2. the repo's integration suite         (cloud_integration_tests, its CI "checks")
#   3. scheduler + 3 workers, run log-summary          -> files=16, errors=24
#   4. kill a worker mid-run, restart it, same answer  (replay from Floci)
#   5. a typed program: sum-squares [2,3,4]            -> 29
#   6. what lean-cloud left in the bucket
#
# Nothing in lean-cloud is modified. The only change from its local Docker setup is
# the "blobs" block of its own config template: endpoint and keys point at Floci.
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENDPOINT=${AWS_ENDPOINT_URL:-http://localhost:4566}
# Containers reach the host's Floci here; nodes.compose.yaml maps it on Linux as well.
IN_DOCKER=${LEAN_CLOUD_FLOCI_ENDPOINT:-http://host.docker.internal:${ENDPOINT##*:}}
PORT=${LEAN_CLOUD_PORT:-8090}
TOKEN=lab-client-token
export AWS_ENDPOINT_URL=$ENDPOINT AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:-test} \
  AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:-test} AWS_DEFAULT_REGION=us-east-1 AWS_PAGER=

say() { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
ok()  { printf '\033[1;32mok\033[0m  %s\n' "$*"; }
die() { printf '\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

for image in lean-cloud-demo:floci lean-cloud-integration:floci lean-cloud-storage-tests:floci; do
  docker image inspect "$image" >/dev/null 2>&1 || die "$image missing — run ./build.sh first"
done
curl -fsS "$ENDPOINT/_floci/health" >/dev/null || die "Floci is not answering at $ENDPOINT"
ok "Floci $(curl -fsS "$ENDPOINT/_floci/health" | jq -r .version) at $ENDPOINT"

# blobs config for a bucket: lean-cloud creates it on first use (provisioned=false).
blobs() { jq -n --arg e "$IN_DOCKER" --arg b "$1" --arg k "$AWS_ACCESS_KEY_ID" --arg s "$AWS_SECRET_ACCESS_KEY" \
  '{provider:"s3",endpoint:$e,bucket:$b,region:"us-east-1",authentication:{kind:"keys",accessKey:$k,secretKey:$s}}'; }

mkdir -p .work
image_id=$(docker image inspect lean-cloud-demo:floci --format '{{.Id}}')
jq --argjson blobs "$(blobs lean-cloud-lab)" --arg image "$image_id" --arg token "$TOKEN" \
  '.blobs=$blobs | .client={deployment:"floci-lab",image:$image,token:$token}' \
  .work/lean-cloud/deploy/config.json > .work/config.json
jq --argjson blobs "$(blobs lean-cloud-integration)" '.blobs=$blobs' .work/config.json > .work/integration.json
blobs lean-cloud-storage-tests > .work/storage.json
chmod 644 .work/*.json   # the images run as an unprivileged user

say "1. lean-cloud's storage contract test against Floci S3"
docker run --rm --add-host host.docker.internal:host-gateway \
  -v "$PWD/.work/storage.json:/cfg.json:ro" lean-cloud-storage-tests:floci /cfg.json

say "2. lean-cloud's integration suite against Floci S3"
docker run --rm --add-host host.docker.internal:host-gateway \
  -v "$PWD/.work/integration.json:/etc/lean-cloud/config.json:ro" \
  lean-cloud-integration:floci /etc/lean-cloud/config.json | grep -v '^@lean-cloud' | grep -E '^(Checking|Real adapters)'

say "3. scheduler + 3 workers, blob store = Floci"
# Fresh nodes every run: lean-cloud pins runs to an image ID and refuses to resume one on
# another, so containers or inbox volumes left from an earlier build must not survive.
docker compose -f nodes.compose.yaml --progress quiet down -v
docker compose -f nodes.compose.yaml --progress quiet up -d --wait
ok "scheduler and 3 workers healthy"

# The console speaks one endpoint: POST /deployment, a versioned JSON request.
api() { curl -fsS -H "Authorization: Bearer $TOKEN" localhost:$PORT/deployment \
  -d "{\"protocolVersion\":1,\"apiVersion\":1,\"deployment\":\"floci-lab\",\"request\":$1}"; }
submit() { api "{\"submit\":{\"id\":\"$1\",\"entry\":\"$2\",\"input\":$3}}" | jq -e '.result.ok' >/dev/null || die "submit $1"; }
result() {  # poll until the run finishes, print its result
  local r
  for _ in $(seq 1 "${2:-120}"); do
    r=$(api "{\"result\":{\"id\":\"$1\"}}" | jq -c '.result.ok // empty')
    [ -n "$r" ] && { jq -r 'if type=="string" then . else tostring end' <<<"$r"; return; }
    sleep 1
  done
  die "run $1 did not finish"
}
run_id() { echo "$1-$(date +%s)"; }

api '"programs"' | jq -r '.result.ok[] | "  program \(.entry): \(.description)"'
sample=$(api '"programs"' | jq -c '.result.ok[] | select(.entry=="log-summary/v1").sampleInput')

id=$(run_id logs); submit "$id" log-summary/v1 "$sample"
out=$(result "$id"); echo "  result $id: $out"
[ "$out" = "files=16, errors=24" ] || die "log-summary returned '$out'"
ok "log-summary on Floci: $out"

say "4. kill worker2 mid-run, then restart it"
id=$(run_id crash); submit "$id" log-summary/v1 "$sample"
sleep 4; docker compose -f nodes.compose.yaml kill -s KILL worker2 >/dev/null 2>&1
ok "worker2 killed 4s into run $id"
sleep 5
[ -z "$(api "{\"result\":{\"id\":\"$id\"}}" | jq -r '.result.ok // empty')" ] && ok "run $id is waiting for worker2's assignment"
docker compose -f nodes.compose.yaml start worker2 >/dev/null 2>&1
out=$(result "$id"); echo "  result $id: $out"
[ "$out" = "files=16, errors=24" ] || die "crash run returned '$out'"
ok "restarted worker2 resumed from its replay records in Floci: $out"

say "5. a typed program: sum-squares"
id=$(run_id squares); submit "$id" "$(api '"programs"' | jq -r '.result.ok[] | select(.entry|startswith("sum-squares")).entry')" '[2,3,4]'
out=$(result "$id"); echo "  result $id: $out"
[ "$out" = "29" ] || die "sum-squares returned '$out'"
ok "sum-squares [2,3,4] = $out"

say "6. what lean-cloud wrote to Floci"
aws s3 ls s3://lean-cloud-lab --recursive | awk '{print $4}' |
  awk -F/ '{k=($1=="runs") ? $1"/<run>/"$3 : $1; n[k]++} END {for (k in n) printf "  %-22s %3d objects\n", k, n[k]}' | sort
echo
printf '\033[1;32mlean-cloud runs on Floci.\033[0m\n'
