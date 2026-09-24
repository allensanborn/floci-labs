# Modifications to the published AWS sample

This directory is [`aws-samples/aws-cdk-loan-broker`](https://github.com/aws-samples/aws-cdk-loan-broker)
at commit `3d3ae8e`, vendored so this lab is self-contained. Apache-2.0; `LICENSE` and
`NOTICE` are the upstream ones.

The point of this track is to show a **published AWS reference architecture running on
Floci essentially unchanged**. So every deviation is listed here. There are five, and only
one of them is about Floci.

---

## 1. Lambda runtime `nodejs18.x` → `nodejs22.x`

`cdk/LoanBroker-RecipientList-stack.ts`, `cdk/LoanBroker-PubSub-stack.ts` — six sites.

Required by **AWS**, not by Floci. The upstream sample pins
`lambda.Runtime.NODEJS_18_X` on all five functions; `nodejs18.x` has reached the point in
its deprecation schedule where new functions can no longer be created, so a fresh
`cdk deploy` of the sample fails against real AWS today. Floci itself is happy to run
either.

## 2. `esbuild` added as a devDependency

`package.json`.

The Pub-Sub stack builds `QuoteAggregatorLambda` and `GetMortgageQuotesLambda` with
`NodejsFunction`, which bundles with esbuild. Upstream declares neither `esbuild` nor a
container-based bundling setup, so on a machine without a running container runtime the
stack does not synth. Adding esbuild makes bundling local and fast. Nothing to do with
Floci.

## 3. `aws-cdk-local` added as a devDependency

`package.json`.

This is the `cdklocal` wrapper — it points the stock CDK CLI at an endpoint instead of
AWS. **No CDK source file knows about it.** All the endpoint wiring lives in environment
variables set by `run.sh`:

```bash
AWS_ENDPOINT_URL=http://localhost:4566
AWS_ENDPOINT_URL_S3=http://localhost:4566
LOCALSTACK_HOSTNAME=localhost
EDGE_PORT=4566
```

Drop those four lines and the same code deploys to a real AWS account.

## 4. Required fix: `quote-aggregator/app.js` declares no loop binding

```diff
-    for (record of event["Records"]) {
+    for (const record of event["Records"]) {
```

This is an **upstream defect**, not a Floci incompatibility, and it is a hard failure:

```
ReferenceError: record is not defined
    at exports.handler (/var/task/index.js:37:8)
```

`record` is assigned with no `var`/`let`/`const`. In a plain CommonJS handler that is a
sloppy-mode implicit global and happens to work. But this function is built by
`NodejsFunction`, and esbuild emits strict-mode output, where an undeclared assignment is
a `ReferenceError`. The aggregator therefore throws on every message, never writes to
DynamoDB and never calls `SendTaskSuccess` — so the workflow always falls through to its
five-second timeout and returns zero quotes.

Worth dwelling on, because it is the argument for this whole lab: this bug is invisible
in the source, invisible at synth time, and invisible in a green `cdk deploy`. It only
appears when you *run the thing*. Finding it took one local execution and no AWS account.

A second, subtler upstream bug is left **unfixed** here, because it does not hard-fail and
fixing it would stop this being the published sample: `taskToken` is `var`-scoped inside
the same loop, so a batch (the event source mapping uses `batchSize: 10`) resolves only
the *last* record's task token. With one execution in flight you never notice. The
`modernized/` track fixes it.

## 5. The one Floci deviation: `FLOCI_NO_LAMBDA_DESTINATIONS`

`bank/app-sns.js` (one fenced block) and `cdk/LoanBroker-PubSub-stack.ts` (one env var).

**The gap.** The Pub-Sub topology moves bank quotes onto the EventBridge bus with
[Lambda destinations](https://docs.aws.amazon.com/lambda/latest/dg/invocation-async.html#invocation-async-destinations):

```ts
onSuccess: new destinations.EventBridgeDestination(config.destinationEventBus),
```

Floci 2.1.0 stores that configuration and provisions it from CloudFormation, but does not
apply it. From `docs/services/lambda.md`:

> The event invoke configuration is stored and returned as AWS does, and
> `AWS::Lambda::EventInvokeConfig` provisions it from a stack. **Asynchronous invocations
> do not yet apply its retry, event age or destination settings.**

So on stock Floci the banks compute their quotes and the return values are dropped. The
stack deploys green, the state machine succeeds, and you get `"Quotes": []` every time,
via the timeout branch. Nothing errors.

**The shim.** With `FLOCI_NO_LAMBDA_DESTINATIONS=1`, the bank handler puts the event on
the bus itself, using the exact envelope AWS's destination would have produced —
`source: "lambda"`, `detail-type: "Lambda Function Invocation Result - Success"`,
`detail.responsePayload` = the return value. `FilterMortgageQuotesRule` then matches
unchanged, and nothing else in the sample has to know. Default off; `run.sh` turns it on.

**Its lifetime.** This is meant to be deleted, and that has been verified rather than
assumed. The gap is tracked as
[floci-io/floci#4193](https://github.com/floci-io/floci/issues/4193) and fixed in
[floci-io/floci#4247](https://github.com/floci-io/floci/pull/4247), merged 2026-09-23
but not yet carried by any released image;
running this lab against a build of that branch with `FLOCI_NO_LAMBDA_DESTINATIONS=0` — the shim off — the quotes
flow through the real destination path and the workflow is resumed by `SendTaskSuccess`
in about two seconds instead of falling into its five-second timeout. Once that ships in
`floci/floci:latest`, drop the block in `bank/app-sns.js`, drop the env var, and the
sample runs with zero Floci-specific code.

---

## Not modified, but worth knowing

**`AWS_ENDPOINT_URL_S3` points at `http://localhost:4566`, not the virtual-hosted
domain.** Floci's own CDK compatibility suite uses `http://s3.localhost.floci.io:4566`,
and that looks like the more correct choice — but it trips a second Floci bug. CDK emits a
path-style `TemplateURL` of `http://s3.localhost.floci.io:4566/<bucket>/<key>`, and
Floci's `CloudFormationService.fetchTemplateFromS3` treats any host ending in the
configured suffix as virtual-hosted, so it parses the bucket as the literal string `"s3"`
and reports `The specified bucket does not exist` — for a bucket that is right there.
Using the plain endpoint sidesteps it. Tracked as
[floci-io/floci#4195](https://github.com/floci-io/floci/issues/4195) and fixed in
[floci-io/floci#4248](https://github.com/floci-io/floci/pull/4248), merged 2026-09-23 and
likewise awaiting a release.

**`teardown.sh` destroys one stack per `cdklocal destroy` invocation** rather than using
`destroy --all`, which deletes only the first stack against Floci. A delete finishes in
milliseconds here, far inside the first poll of CDK's stack-activity monitor, so the
monitor finds the stack already gone, raises, and abandons the rest of the run — exiting
`0` with a stack still standing. Explained in the script and in ../README.md.

**The credit bureau returns a random score between 300 and 900** (`credit-bureau/app.js`),
so a given run may see three quotes, one, or none — each bank has its own
`MIN_CREDIT_SCORE` (400 / 500 / 600). That is upstream behavior and it is left alone;
`run.sh` retries until it observes the path it is asserting on. The `modernized/` track
makes the score injectable so its tests are deterministic.

**The article's null-filtering `Pass` state is missing** from the Recipient List
state machine. [Part 2](https://www.enterpriseintegrationpatterns.com/ramblings/loanbroker_stepfunctions_recipient_list.html)
ends with `"Quotes.$": "$.Quotes[?(@.Quote)].Quote"` to drop declining banks; the CDK repo
never had it, which is why output here looks like
`[{"Quote":null},{"Quote":{...}},{"Quote":{...}}]`. Upstream behavior, left alone,
restored in `modernized/`.
