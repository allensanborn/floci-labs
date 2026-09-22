#!/usr/bin/env bash
# teardown.sh — destroy both Loan Broker stacks, and verify they are actually gone.
#
# Note the shape of this script: it destroys one stack per `cdklocal destroy`
# invocation and then checks the result itself, rather than calling `destroy --all`.
#
# `cdk destroy --all` does not work against Floci today. DeleteStack is synchronous here,
# so a stack is never observable in DELETE_IN_PROGRESS; on real AWS it returns straight
# away and the stack stays describable by name until the delete finishes. CDK starts a
# stack-activity monitor when it issues the delete and polls while it runs — here the
# stack is already gone when the first poll lands, the monitor raises, and CDK abandons
# the rest of the run. With two stacks you get one deleted, one silently left behind,
# and exit code 0.
set -uo pipefail

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

STACKS=("LoanBroker-PubSub-Stack" "LoanBroker-RecipientList-Stack")
CDK=./node_modules/.bin/cdklocal

if ! curl -fsS -m 5 "$ENDPOINT/_floci/health" >/dev/null 2>&1; then
  echo "Floci is not running — nothing to tear down."
  exit 0
fi

exists() { aws cloudformation describe-stacks --stack-name "$1" >/dev/null 2>&1; }

failed=0
for stack in "${STACKS[@]}"; do
  if ! exists "$stack"; then
    printf '  %-32s already gone\n' "$stack"
    continue
  fi
  # The monitoring error above surfaces as a non-zero exit even when the delete worked,
  # so the exit code is not evidence. Ask the API instead.
  $CDK destroy "$stack" --force >/dev/null 2>&1
  if exists "$stack"; then
    printf '  %-32s STILL PRESENT\n' "$stack"
    failed=1
  else
    printf '  %-32s destroyed\n' "$stack"
  fi
done

echo
echo "Remaining in the emulator (both tracks, plus the CDK bootstrap):"
printf '  state machines: %s\n' "$(aws stepfunctions list-state-machines --query 'length(stateMachines)' --output text)"
printf '  functions:      %s\n' "$(aws lambda list-functions --query 'length(Functions)' --output text)"
printf '  tables:         %s\n' "$(aws dynamodb list-tables --query 'length(TableNames)' --output text)"
printf '  topics:         %s\n' "$(aws sns list-topics --query 'length(Topics)' --output text)"

if [ "$failed" -ne 0 ]; then
  echo "Teardown incomplete." >&2
  exit 1
fi
echo "Done. (The CDKToolkit bootstrap stack and its asset bucket are left in place.)"
