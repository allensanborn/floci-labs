# Loan Broker

> Gregor Hohpe's Enterprise Integration Patterns Loan Broker — the **published AWS CDK
> sample, unmodified** — deployed and running on local Floci. Plus a modernized rewrite
> beside it, so you can see what the same architecture looks like in current Step
> Functions idiom. This README is also the test.

## What it shows

- A real, published, multi-service AWS reference architecture deploying to Floci with
  `cdklocal bootstrap && cdklocal deploy` — the stock CDK CLI, the stock templates
- **Step Functions running for real**, not just storing definitions: `Map`, `Catch`,
  `sns:publish.waitForTaskToken`, `SendTaskSuccess` callbacks, JSONata, optimized
  `lambda:invoke` and `dynamodb:getItem` integrations
- Two Enterprise Integration Patterns topologies end to end — **Recipient List**
  (synchronous, broker knows the banks) and **Publish-Subscribe + Aggregator**
  (asynchronous, broker knows nothing), including the task-token callback that resumes a
  parked workflow
- A genuine bug in the published AWS sample that is **invisible until you run it** — and
  how cheap "run it" becomes when running it costs nothing
- Four real Floci gaps, found by running it — documented rather than hidden, with fixes in flight

## Stack

- **Language / runtime:** TypeScript (AWS CDK v2), Node.js 22+, Lambda `nodejs22.x`
  (the CDK CLI prints an untested-Node warning above v22; both tracks were developed and
  tested on v26 anyway, and it is only a warning)
- **AWS services:** Step Functions, Lambda, DynamoDB, SNS, SQS, EventBridge,
  CloudFormation, IAM, CloudWatch Logs, S3 (CDK assets)
- **Tooling:** `aws-cdk-local` (`cdklocal`), `mechanical-markdown` for the README test

## The two tracks

| | |
|---|---|
| [`as-published/`](as-published/) | [`aws-samples/aws-cdk-loan-broker`](https://github.com/aws-samples/aws-cdk-loan-broker) vendored at `3d3ae8e`. Five deviations, each one listed and justified in [`MODIFICATIONS.md`](as-published/MODIFICATIONS.md); exactly one of them is about Floci. This is the "does the real thing work" track. |
| [`modernized/`](modernized/) | The same two topologies, rewritten. JSONata instead of JSONPath, the EIP patterns promoted to named CDK constructs, upstream's defects fixed, deterministic so its assertions are real assertions. This is the "what would you actually build" track. |

They use different resource names, so both can be deployed at once.

---

## Run it

Floci on `localhost:4566`, with the Docker socket mounted — Step Functions here really
invokes Lambda, and Floci runs Lambda in real containers.

<!-- STEP
name: Start Floci
expected_stdout_lines:
  - 'Floci is up'
output_match_mode: substring
match_order: none
timeout_seconds: 300
working_dir: .
-->

```bash
# Uses the Floci you already have running, if you have one.
if ! curl -sf http://localhost:4566/_floci/health > /dev/null 2>&1; then
  docker compose up -d
  for i in $(seq 1 60); do
    curl -sf http://localhost:4566/_floci/health > /dev/null 2>&1 && break
    sleep 2
  done
fi
curl -sf http://localhost:4566/_floci/health | jq '{version, edition}' && echo "Floci is up"
```

<!-- END_STEP -->

### Track 1 — the published AWS sample

`run.sh` bootstraps CDK, deploys both stacks, seeds the recipient list, and runs a loan
request through each topology.

<!-- STEP
name: Deploy and run the published sample
expected_stdout_lines:
  - 'Floci is healthy'
  - 'bootstrapped'
  - 'LoanBroker-RecipientList-Stack'
  - 'LoanBroker-PubSub-Stack'
  - 'LoanBrokerBanksTable seeded with 3 banks'
  - 'all 3 banks were contacted; Map gathered every response'
  - 'Recipient List works on Floci'
  - 'SNS fan-out'
  - 'workflow resumed by callback, not by its 5s timeout'
  - 'Loan Broker (as published) passed on Floci.'
output_match_mode: substring
match_order: none
timeout_seconds: 1200
working_dir: ./as-published
-->

```bash
npm install --no-audit --no-fund
./run.sh
```

<!-- END_STEP -->

### Track 2 — the modernized rewrite

Here the credit score is an input, so one deployment walks every branch: how many banks
lend decides whether the Pub-Sub workflow is resumed by its Aggregator or by its timeout.

<!-- STEP
name: Deploy and run the modernized rewrite
expected_stdout_lines:
  - 'both stacks deployed'
  - 'recipient list seeded with 3 banks'
  - 'declining banks are filtered out, not returned as nulls'
  - 'the aggregator resumed at its quorum of 2'
  - 'quorum never reached, timeout branch returned the partial result'
  - 'timeout branch returned an empty result'
  - 'Loan Broker (modernized) passed on Floci.'
output_match_mode: substring
match_order: none
timeout_seconds: 1200
working_dir: ./modernized
-->

```bash
npm install --no-audit --no-fund
./run.sh
```

<!-- END_STEP -->

### Clean up

<!-- STEP
name: Tear down
expected_stdout_lines:
  - 'Done.'
output_match_mode: substring
match_order: none
timeout_seconds: 600
working_dir: .
-->

```bash
(cd as-published && ./teardown.sh)
(cd modernized && ./teardown.sh)
```

<!-- END_STEP -->

---

## How it works

Three articles, two topologies, one broker. A customer asks for a loan; the broker gets a
credit score, asks banks for quotes, and returns them. The interesting part is *how* it
asks.

### Part 1 — Content Enricher

Both workflows start the same way: the request `{SSN, Amount, Term}` arrives with no
credit score, and a Lambda adds one. The execution ARN rides along as the
**Correlation Identifier**, which is what lets an answer arriving much later be matched
back to the request that caused it.

### Part 2 — Recipient List

```
Get credit score → Fetch bank list (DynamoDB) → Map over banks → invoke each → gather
```

The list of banks is **data, not code** — three Lambda names in one DynamoDB item.
Adding a bank is a `PutItem`, not a deploy. The `Map` state doubles as the aggregator: it
blocks until every iteration finishes, so the broker always knows exactly how many
answers to expect.

The per-bank invoke is the one place CDK cannot help you. `LambdaInvoke` wants an
`IFunction` at synthesis time, but the function name only exists at runtime, in the Map
item — so both tracks drop to `sfn.CustomState` and hand-write that one state's ASL.

### Part 3 — Publish-Subscribe + Aggregator

```
Get credit score
  → publish to SNS with $$.Task.Token, then park
       ↓ (fan-out)
     3 banks, invoked asynchronously, each answering independently
       ↓ onSuccess destination
     EventBridge bus → rule: drop declines, unwrap the payload → SQS
       ↓
     Aggregator: append to DynamoDB, and at 2 quotes → SendTaskSuccess
  → workflow resumes
```

Now the broker does not know who the banks are, or how many there are — they subscribe
themselves. The **task token** is the Return Address: it travels out with the request and
comes back with the answer, and is what lets something entirely outside the workflow
restart it.

The completeness decision has moved out of the workflow too. The Aggregator says "two
quotes is enough"; the workflow says "five seconds is all I'll wait". Neither knows about
the other, and whichever fires first wins. That is the real trade of this topology:
total decoupling, paid for with a correlation id, somewhere to hold partial state, and an
explicit timeout policy.

### Part 5 — the patterns as constructs

Hohpe's point in the CDK article is that automation code should be written in the
vocabulary of the architecture. The published sample gets partway there with
`MessageFilter` / `ContentFilter` / `MessageContentFilter`.
[`modernized/cdk/integration-patterns.ts`](modernized/cdk/integration-patterns.ts) keeps
those and adds `RecipientList`, `ScatterGather` and `Aggregator`, so the stacks read as
patterns rather than as a pile of EventBridge rules.

---

## The bug you only find by running it

The published sample's aggregator has this loop:

```js
for (record of event["Records"]) {
```

No `var`, no `let`, no `const`. In a plain CommonJS handler that is a sloppy-mode implicit
global and it works. But that function is built with `NodejsFunction`, which bundles with
esbuild, whose output is strict-mode — where an undeclared assignment is a `ReferenceError`:

```
ReferenceError: record is not defined
    at exports.handler (/var/task/index.js:37:8)
```

So the aggregator throws on every message, never writes to DynamoDB, never calls
`SendTaskSuccess`. The workflow then always falls through to its five-second timeout and
returns zero quotes — and, because the timeout is *caught*, the execution still reports
`SUCCEEDED`.

Nothing upstream catches this. It is invisible in review, invisible at synth, invisible
in a green `cdk deploy`, and invisible to any assertion that checks only execution status.
You find it by running the thing and looking at the answer. That is the argument for this
lab: locally, running the thing costs nothing, so you do it on every change.

It is also why `run.sh` asserts on **elapsed time** as well as output. A silent
fall-through to the timeout branch reports `SUCCEEDED` too.

---

## What Floci supports here, and the one thing it doesn't

Everything this architecture needs has a real implementation:

| | |
|---|---|
| `arn:aws:states:::lambda:invoke` (optimized + direct ARN) | ✅ |
| `arn:aws:states:::dynamodb:getItem` | ✅ |
| `arn:aws:states:::sns:publish.waitForTaskToken` | ✅ |
| `SendTaskSuccess` / `SendTaskFailure` | ✅ |
| `Map`, `Catch`, `TimeoutSeconds`, `Assign`, JSONata | ✅ |
| SNS → Lambda async fan-out | ✅ |
| EventBridge rule with `exists` filter + `InputPath` → SQS | ✅ |
| SQS event source mapping → Lambda | ✅ |
| DynamoDB `list_append` / `if_not_exists` | ✅ |
| CDK: `bootstrap`, zip assets to S3, `AWS::StepFunctions::StateMachine` | ✅ |

### The one gap

**Lambda async invoke does not apply `onSuccess` / `onFailure` destinations.** Floci's own
docs say so:

> The event invoke configuration is stored and returned as AWS does, and
> `AWS::Lambda::EventInvokeConfig` provisions it from a stack. Asynchronous invocations do
> not yet apply its retry, event age or destination settings.

That is precisely how the Pub-Sub topology moves quotes onto the event bus, so on stock
Floci the banks compute their quotes and the results vanish. Note the failure mode: the
stack deploys green, the workflow succeeds, and you get `"Quotes": []` forever. Nothing
errors.

Both tracks work around it with `FLOCI_NO_LAMBDA_DESTINATIONS=1`, which has the bank
handler publish the exact envelope AWS's destination would have published — so the
EventBridge rule matches unchanged and nothing else knows. It is one fenced block,
default off, and meant to be deleted. Tracked upstream as
[floci-io/floci#4193](https://github.com/floci-io/floci/issues/4193) and fixed by
[floci-io/floci#4247](https://github.com/floci-io/floci/pull/4247), which merged on
2026-09-23 and is **not in a released image yet** — the latest release is 2.1.0, cut
2026-09-15. Until one ships, the shim stays. That fix is
deliberately narrow: it resolves the configuration on the function, so a destination
configured on an *alias* still does not fire
([floci-io/floci#4263](https://github.com/floci-io/floci/issues/4263)). This lab configures
destinations on the function, so it is unaffected either way.

### `cdk destroy --all` deletes only the first stack

A stack delete here finishes in **milliseconds** — far inside the first poll of any client
watching it. `DeleteStack` is genuinely asynchronous (it returns before the delete
completes), but the window is so short that `DELETE_IN_PROGRESS` is never actually
observable. Measured from one process over raw HTTP, 60-resource stack:

```
DeleteStack returned in 2.6 ms
first DescribeStacks 2.9 ms later -> ValidationError: ... does not exist
```

On AWS the same delete takes seconds and the stack reports `DELETE_IN_PROGRESS` by name
throughout. CDK starts a stack-activity monitor when it issues the delete and polls while
it runs — here the stack is already gone when the first poll lands, the monitor raises,
and the rest of the run is abandoned:

```
LoanBroker-PubSub-Stack: destroying... [1/2]
Error occurred while monitoring stack: ValidationError: Stack with id LoanBroker-PubSub-Stack does not exist
```

One stack deleted, one silently left behind — and `cdk destroy --all` still exits `0`.
Both `teardown.sh` scripts therefore destroy one stack per invocation and confirm the
outcome against the API rather than trusting the exit code.

The telling detail is that **deploying** works fine, and `CreateStack` has the same
problem only worse: it blocks the caller for the whole build, so `CREATE_IN_PROGRESS` is
just as invisible. CDK runs the same activity monitor on both. Deploy survives because
when the monitor polls, the stack is *there* in a readable terminal state:

```
after create, DescribeStacks by name -> CREATE_COMPLETE
after delete, DescribeStacks by name -> ValidationError
```

So the difference is not the missing in-progress window — it is that a by-name lookup
after a delete *raises* rather than returning anything. Which is also correct AWS
behaviour, so it is a genuine trade rather than a simple bug. Tracked upstream as
[floci-io/floci#4235](https://github.com/floci-io/floci/issues/4235).

### Two smaller ones, both already fixed upstream but not yet released

- **`ItemSelector` is not evaluated as JSONata** in a JSONata `Map` state. Floci 2.1.0
  resolves it with the JSONPath resolver unconditionally, so every `{% … %}` reaches the
  iteration as a literal string. Fixed in
  [floci-io/floci#3460](https://github.com/floci-io/floci/pull/3460), which landed on
  `main` on 2026-09-16 — one day after the 2.1.0 image was built, so no released image
  carries it yet. The modernized track does not
  hit it, because with assigned variables an `ItemSelector` is unnecessary — each
  iteration reads `$request` and `$credit` directly.
- **A path-style S3 URL against the S3 service host is mis-parsed.**
  ([floci-io/floci#4195](https://github.com/floci-io/floci/issues/4195); fixed by
  [#4248](https://github.com/floci-io/floci/pull/4248), merged 2026-09-23, also not yet
  released.) With
  `AWS_ENDPOINT_URL_S3=http://s3.localhost.floci.io:4566`, CDK emits a `TemplateURL` of
  `http://s3.localhost.floci.io:4566/<bucket>/<key>` and Floci reads the bucket as the
  literal string `"s3"`, then reports `The specified bucket does not exist` for a bucket
  that is right there. Both `run.sh` scripts use the plain endpoint instead.

### Behaviour differences worth knowing

- `Wait` durations and retry backoff are **capped at 30 seconds**
  (`AslExecutor.java:148`). Generally in your favour; surprising if you are timing things.
- `TaskSubmitted` history events are not emitted for `.waitForTaskToken` or `.sync`.
  Only matters if you assert on execution history.
- Floci accepts a CloudFormation resource type it does not implement, stubs it, and lets
  the stack reach `CREATE_COMPLETE`. [`docker-compose.yml`](docker-compose.yml) turns that
  off — a lab claiming "this really deploys" should not pass on a green-but-empty stack.

---

## This README is the test

The bash blocks above are annotated for
[mechanical-markdown](https://github.com/dapr/mechanical-markdown), the tool the
[Dapr quickstarts](https://github.com/dapr/quickstarts) use. `mm.py` runs them and checks
their output against the `expected_stdout_lines` in each annotation, so a README that has
drifted from reality fails.

```bash
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
./validate.sh
```

`validate.sh` adds one thing `mm.py` cannot express — a third exit code:

| | |
|---|---|
| `0` | the README ran and every expectation held |
| `1` | the README ran and something did not match — a real failure |
| `2` | the README could not be run: a missing tool, or no Floci |

Without the `2`, stopping Floci would make the suite report "nothing ran, nothing failed".
A skip that reports success is worse than a failure, because it is the one result you
believe without checking.

## Try changing...

- **Add a fourth bank.** In `as-published/`, that is one `aws dynamodb put-item` against
  `LoanBrokerBanksTable` plus a Lambda — no redeploy of the workflow. That is the whole
  point of Recipient List.
- **Move the quorum.** `QUORUM` in `modernized/cdk/pubsub-stack.ts` is `2`. Set it to `3`
  and watch runs that used to resume by callback start timing out instead.
- **Shorten the timeout** to `Duration.seconds(1)` and watch the Aggregator lose the race
  it was winning.
- **Break a bank on purpose** — `throw new Error()` in `bank/app-sns.js` — and see the
  `onFailure` path (and, today, the gap above) from the other side.
- **Turn the shim off** (`FLOCI_NO_LAMBDA_DESTINATIONS=0 ./run.sh`) to watch the failure
  mode the gap actually produces: green stack, `SUCCEEDED` execution, zero quotes, every
  time.

## Beyond the articles

Not built here. Each is a reasonable next lab:

- **Best-quote selection.** Every version returns all quotes and leaves choosing to the
  caller. Hohpe flags it as future work. A `Map` + sort, or a Choice chain.
- **An API Gateway front door.** Neither the articles nor the sample ever built one — the
  broker is only reachable by `start-execution`. Floci supports API Gateway v1 and v2 with
  Step Functions integrations.
- **A failure lane.** Force `States.Timeout` and bank errors deliberately, assert on the
  `Catch` branches, and use Floci's `SFN_MOCK_CONFIG` (Step Functions Local's mock format)
  to drive integrations that would otherwise be awkward to fail on demand.
- **Distributed Map** over a bank list too large for an inline `Map` — read the recipients
  from S3 with `ItemReader`, which Floci implements.
- **The article's correlation trick.** Part 3 concatenates `executionId::taskToken` with
  the `States.Format` intrinsic so correlation id and return address travel as one value.
  The CDK sample replaced it with a message body; the modernized track uses two explicit
  fields. The intrinsic version is worth writing for comparison.
- **Saga / compensation.** Part 1's sharpest criticism is that Step Functions has no
  built-in compensation. Building it by hand here would show exactly what that costs.

## Credit

- Gregor Hohpe's [Enterprise Integration Patterns](https://www.enterpriseintegrationpatterns.com/),
  and the Loan Broker series:
  [Part 1](https://www.enterpriseintegrationpatterns.com/ramblings/loanbroker_stepfunctions.html) ·
  [Part 2](https://www.enterpriseintegrationpatterns.com/ramblings/loanbroker_stepfunctions_recipient_list.html) ·
  [Part 3](https://www.enterpriseintegrationpatterns.com/ramblings/loanbroker_stepfunctions_pubsub.html) ·
  [Part 4](https://www.enterpriseintegrationpatterns.com/ramblings/loanbroker_automation.html) ·
  [Part 5](https://www.enterpriseintegrationpatterns.com/ramblings/loanbroker_cdk.html)
- [`aws-samples/aws-cdk-loan-broker`](https://github.com/aws-samples/aws-cdk-loan-broker)
  by Luis Morales (Apache-2.0), vendored in `as-published/`.
- [mechanical-markdown](https://github.com/dapr/mechanical-markdown), by the Dapr project.

## Author

[allensanborn](https://github.com/allensanborn)
