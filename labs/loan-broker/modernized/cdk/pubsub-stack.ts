/**
 * Loan Broker — Publish-Subscribe + Aggregator (Hohpe, Part 3).
 *
 * https://www.enterpriseintegrationpatterns.com/ramblings/loanbroker_stepfunctions_pubsub.html
 *
 * The broker publishes one request and parks, carrying a task token. It does not know
 * which banks exist or how many will answer — they subscribe themselves. Each bank's
 * answer travels: onSuccess destination → EventBridge bus → rule (drops declines,
 * strips the envelope) → SQS → Aggregator. The Aggregator decides when "enough" quotes
 * have arrived and resumes the workflow with SendTaskSuccess.
 *
 * Two policies decide the outcome and neither component knows the other exists:
 * the Aggregator's completeness rule (two quotes) and the task's timeout (five seconds).
 * Whichever fires first wins — which is exactly why the timeout branch has to produce
 * the same shape as the happy path. The published sample's does not; this one's does.
 */
import { CfnOutput, Duration, RemovalPolicy, Stack, StackProps } from "aws-cdk-lib";
import { Construct } from "constructs";
import * as dynamodb from "aws-cdk-lib/aws-dynamodb";
import * as lambda from "aws-cdk-lib/aws-lambda";
import * as destinations from "aws-cdk-lib/aws-lambda-destinations";
import { SnsEventSource } from "aws-cdk-lib/aws-lambda-event-sources";
import { EventBus } from "aws-cdk-lib/aws-events";
import * as logs from "aws-cdk-lib/aws-logs";
import * as sfn from "aws-cdk-lib/aws-stepfunctions";
import * as tasks from "aws-cdk-lib/aws-stepfunctions-tasks";
import * as sns from "aws-cdk-lib/aws-sns";
import * as sqs from "aws-cdk-lib/aws-sqs";
import * as path from "path";

import {
  Aggregator,
  ContentFilter,
  MessageContentFilter,
  MessageFilter,
  ScatterGather,
} from "./integration-patterns";
import { BANKS, BankConfig, fixedCreditScore, namePrefix } from "./banks";

/** How many quotes the Aggregator waits for before resuming the workflow. */
const QUORUM = 2;
/** How long the workflow waits for the Aggregator before taking the partial result. */
const QUOTE_TIMEOUT = Duration.seconds(5);

export class PubSubStack extends Stack {
  constructor(scope: Construct, id: string, props?: StackProps) {
    super(scope, id, props);

    const prefix = namePrefix();

    const creditBureau = new lambda.Function(this, "CreditBureau", {
      runtime: lambda.Runtime.NODEJS_22_X,
      handler: "app.handler",
      functionName: `${prefix}CreditBureau-PubSub`,
      code: lambda.Code.fromAsset(path.join(__dirname, "..", "lambda", "credit-bureau")),
      environment: fixedCreditScore(),
    });

    const quoteEventBus = new EventBus(this, "QuoteEventBus", {
      eventBusName: `${prefix}MortgageQuotes`,
    });

    const quoteQueue = new sqs.Queue(this, "QuoteQueue", {
      queueName: `${prefix}MortgageQuotes`,
      retentionPeriod: Duration.minutes(5),
      removalPolicy: RemovalPolicy.DESTROY,
    });

    // A bank that declines returns null, so its destination event carries no bankId.
    // Filtering on "bankId exists" is what keeps declines off the queue entirely —
    // the Aggregator never sees them and never has to know they happened.
    new MessageContentFilter(this, "KeepOnlyRealQuotes", {
      sourceEventBus: quoteEventBus,
      targetQueue: quoteQueue,
      messageFilter: MessageFilter.responsePayloadHas(this, "HasBankId", "bankId"),
      contentFilter: ContentFilter.lambdaResponsePayload(this, "UnwrapPayload"),
    });

    const requestTopic = new sns.Topic(this, "QuoteRequestTopic", {
      topicName: `${prefix}MortgageQuoteRequest`,
      displayName: "Mortgage quote requests",
    });

    const bankFunctions = BANKS.map((bank: BankConfig) => {
      const fn = new lambda.Function(this, `Bank${bank.id}`, {
        runtime: lambda.Runtime.NODEJS_22_X,
        handler: "app-sns.handler",
        functionName: `${prefix}Bank${bank.id}-PubSub`,
        code: lambda.Code.fromAsset(path.join(__dirname, "..", "lambda", "bank")),
        environment: {
          BANK_ID: bank.id,
          BASE_RATE: String(bank.baseRate),
          MAX_LOAN_AMOUNT: String(bank.maxLoanAmount),
          MIN_CREDIT_SCORE: String(bank.minCreditScore),
          QUOTE_EVENT_BUS: quoteEventBus.eventBusName,
          // See lambda/bank/app-sns.js. Floci does not apply onSuccess destinations yet.
          FLOCI_NO_LAMBDA_DESTINATIONS: process.env.FLOCI_NO_LAMBDA_DESTINATIONS ?? "0",
        },
        onSuccess: new destinations.EventBridgeDestination(quoteEventBus),
      });
      fn.addEventSource(new SnsEventSource(requestTopic));
      quoteEventBus.grantPutEventsTo(fn);
      return fn;
    });

    // Partial aggregates, keyed by correlation id (the execution ARN).
    const aggregateTable = new dynamodb.Table(this, "QuoteAggregates", {
      tableName: `${prefix}MortgageQuotes`,
      partitionKey: { name: "Id", type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      removalPolicy: RemovalPolicy.DESTROY,
    });

    const aggregator = new Aggregator(this, "QuoteAggregator", {
      source: quoteQueue,
      store: aggregateTable,
      completeAfter: QUORUM,
      functionName: `${prefix}QuoteAggregator`,
      entry: path.join(__dirname, "..", "lambda", "quote-aggregator", "app.js"),
    });

    // ---- the workflow -----------------------------------------------------

    const getCreditScore = tasks.LambdaInvoke.jsonata(this, "Get credit score", {
      lambdaFunction: creditBureau,
      payload: sfn.TaskInput.fromObject({
        SSN: "{% $states.input.SSN %}",
        RequestId: "{% $states.context.Execution.Id %}",
        // Optional per-request score override, so one deployment can demonstrate every
        // branch. A JSONata expression that resolves to nothing fails the state, so the
        // absent case has to be spelled out rather than left to fall through.
        ForceScore: "{% $exists($states.input.ForceScore) ? $states.input.ForceScore : 0 %}",
      }),
      assign: {
        request: "{% $states.input %}",
        credit: `{% { "Score": $states.result.Payload.body.score,
                      "History": $states.result.Payload.body.history } %}`,
      },
      retryOnServiceExceptions: false,
    });

    const askEveryBank = new ScatterGather(this, "AskEveryBank", {
      topic: requestTopic,
      request: `{% { "SSN": $request.SSN, "Amount": $request.Amount,
                     "Term": $request.Term, "Credit": $credit } %}`,
      timeout: QUOTE_TIMEOUT,
      resultVariable: "quotes",
    });

    // Timeout branch. The published sample calls a Lambda here purely to read one item
    // out of DynamoDB — its own source says `// TODO: Replace with DynamoDB Get Item
    // call`. Step Functions can do that itself, so that whole function is deleted.
    const readPartialQuotes = tasks.DynamoGetItem.jsonata(this, "Read partial quotes", {
      table: aggregateTable,
      key: { Id: tasks.DynamoAttributeValue.fromString("{% $states.context.Execution.Id %}") },
      assign: {
        quotes: `{% [ $map($exists($states.result.Item.quotes) ? $states.result.Item.quotes.L : [],
                           function($q) { { "bankId": $q.M.bankId.S, "rate": $number($q.M.rate.N) } }) ] %}`,
      },
    });

    // Both branches converge here, so the caller sees one shape either way.
    const buildResponse = sfn.Pass.jsonata(this, "Build response", {
      outputs: `{% {
        "SSN": $request.SSN,
        "Amount": $request.Amount,
        "Term": $request.Term,
        "Credit": $credit,
        "Quotes": [ $quotes ]
      } %}`,
    });

    askEveryBank.task.addCatch(readPartialQuotes.next(buildResponse), {
      errors: ["States.Timeout"],
    });

    const stateMachine = new sfn.StateMachine(this, "LoanBroker", {
      stateMachineName: `${prefix}LoanBroker-PubSub`,
      queryLanguage: sfn.QueryLanguage.JSONATA,
      stateMachineType: sfn.StateMachineType.STANDARD,
      timeout: Duration.minutes(5),
      definitionBody: sfn.DefinitionBody.fromChainable(
        sfn.Chain.start(getCreditScore).next(askEveryBank.task).next(buildResponse)
      ),
      logs: {
        destination: new logs.LogGroup(this, "LoanBrokerLogGroup", {
          removalPolicy: RemovalPolicy.DESTROY,
          retention: logs.RetentionDays.ONE_DAY,
        }),
        level: sfn.LogLevel.ALL,
        includeExecutionData: true,
      },
    });

    requestTopic.grantPublish(stateMachine);
    aggregateTable.grantReadData(stateMachine);
    // The Aggregator lives outside the workflow but must be able to resume it.
    stateMachine.grantTaskResponse(aggregator.handler);

    new CfnOutput(this, "LoanBrokerArn", { value: stateMachine.stateMachineArn });
    new CfnOutput(this, "QuoteEventBusName", { value: quoteEventBus.eventBusName });
    void bankFunctions;
  }
}
