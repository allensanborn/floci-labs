#!/usr/bin/env bash
# run.sh — deploy the published AWS CDK Loan Broker sample to local Floci and prove
# both topologies actually work: the Recipient List (Part 2) and the Pub-Sub /
# Aggregator (Part 3).
#
# This is aws-samples/aws-cdk-loan-broker, vendored. See MODIFICATIONS.md for every
# byte that differs from upstream — there are five, and only one is about Floci.
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENDPOINT="${AWS_ENDPOINT_URL:-http://localhost:4566}"
export AWS_ENDPOINT_URL="$ENDPOINT"
# Path-style S3. Floci's own CDK suite uses http://s3.localhost.floci.io:4566, but that
# trips a template-URL parsing bug — see "Not modified, but worth knowing" in
# MODIFICATIONS.md.
export AWS_ENDPOINT_URL_S3="${AWS_ENDPOINT_URL_S3:-$ENDPOINT}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export AWS_REGION="$AWS_DEFAULT_REGION"
export CDK_DEFAULT_ACCOUNT="${CDK_DEFAULT_ACCOUNT:-000000000000}"
export CDK_DEFAULT_REGION="$AWS_DEFAULT_REGION"

# aws-cdk-local still reads these two; derive them from the endpoint.
HOSTPORT="${ENDPOINT#*://}"
export LOCALSTACK_HOSTNAME="${HOSTPORT%%:*}"
export EDGE_PORT="${HOSTPORT##*:}"

# Floci does not apply onSuccess destinations yet. See MODIFICATIONS.md #5.
export FLOCI_NO_LAMBDA_DESTINATIONS="${FLOCI_NO_LAMBDA_DESTINATIONS:-1}"

CDK=./node_modules/.bin/cdklocal

say() { printf '\n\033[1;33m== %s\033[0m\n' "$*"; }
ok()  { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

# Exit 2 means "could not run", never "passed". A skip that reports success is worse
# than a failure.
need() { command -v "$1" >/dev/null || { echo "  ✗ $1 is required but not installed" >&2; exit 2; }; }

say "Pre-flight"
need node
need npm
need aws
need jq
curl -fsS -m 5 "$ENDPOINT/_floci/health" >/dev/null 2>&1 || {
  echo "  ✗ Floci is not answering at $ENDPOINT" >&2
  echo "    Start it with:  docker compose up -d   (from the lab directory)" >&2
  exit 2
}
ok "Floci is healthy ($(curl -fsS "$ENDPOINT/_floci/health" | jq -r .version))"

[ -d node_modules ] || { say "Installing CDK dependencies"; npm install --no-audit --no-fund >/dev/null; }
ok "dependencies present"

say "Bootstrap the CDK environment"
# Creates the CDKToolkit stack and the asset bucket, exactly as against real AWS.
$CDK bootstrap --force >/dev/null
ok "aws://$CDK_DEFAULT_ACCOUNT/$CDK_DEFAULT_REGION bootstrapped"

say "Deploy both stacks"
$CDK deploy --all --require-approval never >/dev/null
RL_ARN=$(aws cloudformation describe-stacks --stack-name LoanBroker-RecipientList-Stack \
  --query "Stacks[0].Outputs[?OutputKey=='LoanBrokerArn'].OutputValue" --output text)
PS_ARN=$(aws cloudformation describe-stacks --stack-name LoanBroker-PubSub-Stack \
  --query "Stacks[0].Outputs[?OutputKey=='LoanBrokerArn'].OutputValue" --output text)
[ -n "$RL_ARN" ] && [ -n "$PS_ARN" ] || die "stack outputs missing"
ok "LoanBroker-RecipientList-Stack"
ok "LoanBroker-PubSub-Stack"

# ---------------------------------------------------------------- Recipient List

say "Part 2 — Recipient List: seed the list of banks"
# The recipient list is *data*, not code: three Lambda names in a DynamoDB item. Adding
# a bank means editing this item, not redeploying the workflow.
aws dynamodb put-item --table-name LoanBrokerBanksTable --item '{
  "Type": {"S":"Home"},
  "BankAddress": {"L":[{"S":"BankRecipientPremium"},{"S":"BankRecipientUniversal"},{"S":"BankRecipientPawnshop"}]}
}'
ok "LoanBrokerBanksTable seeded with 3 banks"

say "Part 2 — run a loan request through the Recipient List broker"
EX=$(aws stepfunctions start-execution --state-machine-arn "$RL_ARN" \
  --name "recipient-list-$(date +%s)" \
  --input '{"SSN":"123-45-6789","Amount":500000,"Term":30}' \
  --query executionArn --output text)
for _ in $(seq 1 60); do
  ST=$(aws stepfunctions describe-execution --execution-arn "$EX" --query status --output text)
  [ "$ST" != RUNNING ] && break
  sleep 1
done
[ "$ST" = SUCCEEDED ] || die "Recipient List execution ended $ST"
OUT=$(aws stepfunctions describe-execution --execution-arn "$EX" --query output --output text)
echo "$OUT" | jq '{Score: .Credit.Score, Banks: .Banks.BankAddress, Quotes: .Quotes}'

# Every bank in the list was asked. The Map state is the aggregator: it blocks until all
# three iterations finish, so there is always one entry per bank — a quote, or nothing,
# depending on that bank's MIN_CREDIT_SCORE against this run's random credit score.
[ "$(echo "$OUT" | jq '.Quotes | length')" -eq 3 ] || die "expected one Map result per bank"
ok "all 3 banks were contacted; Map gathered every response"
ok "Recipient List works on Floci"

# ----------------------------------------------------------------------- Pub-Sub

say "Part 3 — Pub-Sub + Aggregator: the callback path"
# The broker does not know who the banks are here — it publishes once, with a task token,
# and parks. The aggregator (outside the workflow) resumes it with SendTaskSuccess once
# two quotes have arrived. The state machine also carries a 5s timeout with a Catch, so
# a run that never gets two quotes still succeeds, via the *other* path.
#
# The credit bureau returns a random score (300-900) and the three banks require 400/500
# /600, so whether two banks quote is luck. Retry until we observe the callback path —
# and assert on elapsed time, because a silent fall-through to the timeout branch also
# reports SUCCEEDED and would otherwise pass.
ATTEMPTS="${PUBSUB_ATTEMPTS:-8}"
CALLBACK_SEEN=0
for try in $(seq 1 "$ATTEMPTS"); do
  EX=$(aws stepfunctions start-execution --state-machine-arn "$PS_ARN" \
    --name "pubsub-$try-$(date +%s)" \
    --input '{"SSN":"123-45-6789","Amount":500000,"Term":30}' \
    --query executionArn --output text)
  T0=$(date +%s)
  for _ in $(seq 1 60); do
    ST=$(aws stepfunctions describe-execution --execution-arn "$EX" --query status --output text)
    [ "$ST" != RUNNING ] && break
    sleep 1
  done
  T1=$(date +%s)
  [ "$ST" = SUCCEEDED ] || die "Pub-Sub execution ended $ST"
  OUT=$(aws stepfunctions describe-execution --execution-arn "$EX" --query output --output text)
  NQ=$(echo "$OUT" | jq '.Quotes | length')
  SCORE=$(echo "$OUT" | jq '.Credit.Score')
  ELAPSED=$((T1 - T0))
  printf '  attempt %d: credit score %s, %s quotes, %ss\n' "$try" "$SCORE" "$NQ" "$ELAPSED"
  if [ "$NQ" -ge 2 ] && [ "$ELAPSED" -lt 5 ]; then
    CALLBACK_SEEN=1
    echo "$OUT" | jq '{Score: .Credit.Score, Quotes: .Quotes}'
    break
  fi
done
[ "$CALLBACK_SEEN" -eq 1 ] || die "never observed the SendTaskSuccess path in $ATTEMPTS attempts"
ok "SNS fan-out → EventBridge → SQS → aggregator → SendTaskSuccess"
ok "workflow resumed by callback, not by its 5s timeout"

say "What just happened"
cat <<'EOF'
  Two Enterprise Integration Patterns topologies, deployed by the stock AWS CDK
  through CloudFormation, running against a local emulator:

    Recipient List   Step Functions Map over a list of banks held in DynamoDB
    Pub-Sub          sns:publish.waitForTaskToken, a task token carried through
                     SNS -> Lambda -> EventBridge -> SQS, and an Aggregator that
                     resumes the workflow with SendTaskSuccess

  No AWS account. No bill. The only difference from a real deployment is four
  environment variables.
EOF

printf '\n\033[1;32mLoan Broker (as published) passed on Floci.\033[0m\n'
echo "Tear down with:  ./teardown.sh"
