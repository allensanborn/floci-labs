#!/usr/bin/env bash
# run.sh — deploy the modernized Loan Broker and walk every branch of both workflows.
#
# Same two topologies as ../as-published/, rewritten: JSONata instead of JSONPath, the
# upstream defects fixed, and the EIP patterns promoted to named CDK constructs.
#
# The credit bureau takes a per-request score, so one deployment demonstrates every
# path. Each bank has its own threshold (PawnShop 400, Universal 500, Premium 600), so
# the score alone decides how many quotes come back — and therefore which branch runs.
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENDPOINT="${AWS_ENDPOINT_URL:-http://localhost:4566}"
export AWS_ENDPOINT_URL="$ENDPOINT"
export AWS_ENDPOINT_URL_S3="${AWS_ENDPOINT_URL_S3:-$ENDPOINT}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export AWS_REGION="$AWS_DEFAULT_REGION"
export CDK_DEFAULT_ACCOUNT="${CDK_DEFAULT_ACCOUNT:-000000000000}"
export CDK_DEFAULT_REGION="$AWS_DEFAULT_REGION"

HOSTPORT="${ENDPOINT#*://}"
export LOCALSTACK_HOSTNAME="${HOSTPORT%%:*}"
export EDGE_PORT="${HOSTPORT##*:}"

# Floci does not apply onSuccess destinations yet — see ../README.md, "The one gap".
export FLOCI_NO_LAMBDA_DESTINATIONS="${FLOCI_NO_LAMBDA_DESTINATIONS:-1}"
PREFIX="${LOAN_BROKER_PREFIX:-Modern}"

CDK=./node_modules/.bin/cdklocal

say() { printf '\n\033[1;33m== %s\033[0m\n' "$*"; }
ok()  { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || { echo "  ✗ $1 is required but not installed" >&2; exit 2; }; }

say "Pre-flight"
need node; need npm; need aws; need jq
curl -fsS -m 5 "$ENDPOINT/_floci/health" >/dev/null 2>&1 || {
  echo "  ✗ Floci is not answering at $ENDPOINT" >&2
  echo "    Start it with:  docker compose up -d   (from the lab directory)" >&2
  exit 2
}
ok "Floci is healthy ($(curl -fsS "$ENDPOINT/_floci/health" | jq -r .version))"

[ -d node_modules ] || { say "Installing CDK dependencies"; npm install --no-audit --no-fund >/dev/null; }

say "Deploy"
$CDK bootstrap --force >/dev/null
$CDK deploy --all --require-approval never >/dev/null
RL=$(aws cloudformation describe-stacks --stack-name LoanBroker-Modern-RecipientList \
  --query "Stacks[0].Outputs[?OutputKey=='LoanBrokerArn'].OutputValue" --output text)
PS=$(aws cloudformation describe-stacks --stack-name LoanBroker-Modern-PubSub \
  --query "Stacks[0].Outputs[?OutputKey=='LoanBrokerArn'].OutputValue" --output text)
[ -n "$RL" ] && [ -n "$PS" ] || die "stack outputs missing"
ok "both stacks deployed"

aws dynamodb put-item --table-name "${PREFIX}BankDirectory" --item "{
  \"Type\": {\"S\":\"Home\"},
  \"BankAddress\": {\"L\":[{\"S\":\"${PREFIX}BankPremium\"},{\"S\":\"${PREFIX}BankUniversal\"},{\"S\":\"${PREFIX}BankPawnShop\"}]}
}"
ok "recipient list seeded with 3 banks"

# Runs one execution, prints a one-line summary, and leaves the result in $QUOTES /
# $ELAPSED / $BANKS for the caller to assert on.
execute() {
  local sm="$1" score="$2" label="$3" ex t0 t1 out
  ex=$(aws stepfunctions start-execution --state-machine-arn "$sm" \
        --name "${label}-$(date +%s)-$RANDOM" \
        --input "{\"SSN\":\"123-45-6789\",\"Amount\":500000,\"Term\":30,\"ForceScore\":$score}" \
        --query executionArn --output text)
  t0=$(date +%s)
  for _ in $(seq 1 60); do
    STATUS=$(aws stepfunctions describe-execution --execution-arn "$ex" --query status --output text)
    [ "$STATUS" != RUNNING ] && break
    sleep 1
  done
  t1=$(date +%s)
  [ "$STATUS" = SUCCEEDED ] || die "$label ended $STATUS"
  out=$(aws stepfunctions describe-execution --execution-arn "$ex" --query output --output text)
  ELAPSED=$((t1 - t0))
  QUOTES=$(echo "$out" | jq '.Quotes | length')
  BANKS=$(echo "$out" | jq -c '[.Quotes[].bankId] | sort')
  printf '  credit score %-4s → %s quote(s) in %ss  %s\n' "$score" "$QUOTES" "$ELAPSED" "$BANKS"
}

# --------------------------------------------------------------- Recipient List

say "Recipient List — the score decides how many banks lend"
# PawnShop lends from 400, Universal from 500, Premium from 600. The Map state asks all
# three every time; the final Pass drops the ones that declined. That Pass is in the
# article and missing from the published sample, which is why its output is full of
# nulls and this one's is not.
execute "$RL" 650 rl-all;  [ "$QUOTES" -eq 3 ] || die "expected 3 quotes at 650"
execute "$RL" 550 rl-two;  [ "$QUOTES" -eq 2 ] || die "expected 2 quotes at 550"
execute "$RL" 450 rl-one;  [ "$QUOTES" -eq 1 ] || die "expected 1 quote at 450"
execute "$RL" 350 rl-none; [ "$QUOTES" -eq 0 ] || die "expected 0 quotes at 350"
ok "declining banks are filtered out, not returned as nulls"
ok "the recipient list is data — three names in a DynamoDB item"

# ----------------------------------------------------------------------- Pub-Sub

say "Pub-Sub — two quotes, or five seconds, whichever comes first"
# The Aggregator resumes the workflow as soon as it holds 2 quotes. If fewer than 2 ever
# arrive, nothing resumes it and the task times out at 5s into its Catch branch, which
# reads whatever partial quotes did land. Elapsed time is what tells the two apart — both
# report SUCCEEDED, so asserting on status alone would pass either way.
execute "$PS" 650 ps-callback
[ "$QUOTES" -eq 2 ] || die "expected the aggregator to stop at its quorum of 2"
[ "$ELAPSED" -lt 5 ] || die "expected the callback path, got the timeout"
ok "3 banks lent, the aggregator resumed at its quorum of 2 — it does not wait for the rest"

execute "$PS" 450 ps-timeout
[ "$QUOTES" -eq 1 ] || die "expected the single partial quote"
[ "$ELAPSED" -ge 5 ] || die "expected the 5s timeout branch"
ok "1 bank lent, quorum never reached, timeout branch returned the partial result"

execute "$PS" 350 ps-empty
[ "$QUOTES" -eq 0 ] || die "expected no quotes"
[ "$ELAPSED" -ge 5 ] || die "expected the 5s timeout branch"
ok "0 banks lent, timeout branch returned an empty result — same shape, not a failure"

say "What changed from as-published/"
cat <<'EOF'
  · JSONata + assigned variables instead of JSONPath + ResultPath plumbing
  · Recipient List / Scatter-Gather / Aggregator are named CDK constructs
  · the article's null-filtering step, restored
  · the aggregator's strict-mode crash and its batch task-token bug, fixed
  · the timeout branch returns the same shape as the callback branch
  · one Lambda deleted: Step Functions reads DynamoDB itself
EOF

printf '\n\033[1;32mLoan Broker (modernized) passed on Floci.\033[0m\n'
echo "Tear down with:  ./teardown.sh"
