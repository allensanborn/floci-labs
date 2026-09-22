/**
 * Enterprise Integration Patterns as CDK constructs.
 *
 * This is the thesis of Hohpe's Part 5 (loanbroker_cdk.html): automation code should be
 * written in the vocabulary of the architecture, not the vocabulary of the platform. A
 * reader should see "Recipient List" and "Aggregator", not "an EventBridge rule whose
 * pattern happens to encode the Lambda Destinations envelope".
 *
 * The published sample stops at three filter constructs. This file keeps those and adds
 * the three patterns that actually carry the Loan Broker: Recipient List, Scatter-Gather
 * and Aggregator.
 *
 * https://www.enterpriseintegrationpatterns.com/patterns/messaging/
 */
import { Construct } from "constructs";
import { Duration } from "aws-cdk-lib";
import { IQueue } from "aws-cdk-lib/aws-sqs";
import { EventBus, Rule, RuleTargetInput, EventPattern } from "aws-cdk-lib/aws-events";
import * as targets from "aws-cdk-lib/aws-events-targets";
import * as dynamodb from "aws-cdk-lib/aws-dynamodb";
import * as sns from "aws-cdk-lib/aws-sns";
import * as lambda from "aws-cdk-lib/aws-lambda";
import { NodejsFunction } from "aws-cdk-lib/aws-lambda-nodejs";
import { SqsEventSource } from "aws-cdk-lib/aws-lambda-event-sources";
import * as sfn from "aws-cdk-lib/aws-stepfunctions";
import * as tasks from "aws-cdk-lib/aws-stepfunctions-tasks";

// ---------------------------------------------------------------------------
// Content Filter — strip a message down to the part the receiver cares about.
// https://www.enterpriseintegrationpatterns.com/patterns/messaging/ContentFilter.html
// ---------------------------------------------------------------------------

export interface ContentFilterProps {
  readonly jsonPath: string;
}

export class ContentFilter extends Construct {
  public readonly ruleTargetInput: RuleTargetInput;

  constructor(scope: Construct, id: string, props: ContentFilterProps) {
    super(scope, id);
    this.ruleTargetInput = RuleTargetInput.fromEventPath(props.jsonPath);
  }

  /**
   * The payload a Lambda returned, lifted out of the async-invoke result envelope AWS
   * wraps around it. This is the leaky detail Part 4 complains about — the rule has to
   * know the shape of a Lambda Destinations event. Naming it is the point.
   */
  static lambdaResponsePayload(scope: Construct, id: string): ContentFilter {
    return new ContentFilter(scope, id, { jsonPath: "$.detail.responsePayload" });
  }
}

// ---------------------------------------------------------------------------
// Message Filter — drop messages the receiver is not interested in.
// https://www.enterpriseintegrationpatterns.com/patterns/messaging/Filter.html
// ---------------------------------------------------------------------------

export interface MessageFilterProps extends EventPattern {}

export class MessageFilter extends Construct {
  public readonly eventPattern: EventPattern;

  constructor(scope: Construct, id: string, props: MessageFilterProps) {
    super(scope, id);
    this.eventPattern = props;
  }

  /** Pass only messages whose response payload carries `field`. */
  static responsePayloadHas(scope: Construct, id: string, field: string): MessageFilter {
    return new MessageFilter(scope, id, {
      detail: { responsePayload: { [field]: [{ exists: true }] } },
    });
  }
}

export interface MessageContentFilterProps {
  readonly sourceEventBus: EventBus;
  readonly targetQueue: IQueue;
  readonly messageFilter: MessageFilter;
  readonly contentFilter: ContentFilter;
}

/** A Message Filter and a Content Filter composed into one bus → queue hop. */
export class MessageContentFilter extends Construct {
  public readonly rule: Rule;

  constructor(scope: Construct, id: string, props: MessageContentFilterProps) {
    super(scope, id);

    // Upstream passes `scope` here, which makes the rule a sibling of this construct
    // rather than its child. `this` keeps the construct tree honest.
    this.rule = new Rule(this, "Rule", {
      eventBus: props.sourceEventBus,
      eventPattern: props.messageFilter.eventPattern,
    });

    this.rule.addTarget(
      new targets.SqsQueue(props.targetQueue, {
        message: props.contentFilter.ruleTargetInput,
      })
    );
  }
}

// ---------------------------------------------------------------------------
// Recipient List — send a message to a set of receivers chosen at runtime.
// https://www.enterpriseintegrationpatterns.com/patterns/messaging/RecipientList.html
// ---------------------------------------------------------------------------

export interface RecipientListProps {
  /** Table holding the list. One item per list, a list of receiver names inside it. */
  readonly directory: dynamodb.ITable;
  /** Partition-key value naming which list to read (here: the product, "Home"). */
  readonly listKey: string;
  /** Attribute on that item holding the receiver names. */
  readonly listAttribute: string;
  /**
   * Run once per recipient. Its `$states.input` is that recipient's name; everything
   * else it needs it reads from variables assigned earlier in the workflow.
   */
  readonly recipientTask: sfn.IChainable;
  /** Variable the gathered responses are assigned to. */
  readonly resultVariable: string;
}

/**
 * Looks the recipients up, then fans out to them.
 *
 * The list lives in data, not in the workflow: adding a bank is a DynamoDB write, not a
 * deploy. That is the whole reason to reach for this pattern instead of hardcoding the
 * receivers into the state machine.
 */
export class RecipientList extends Construct {
  public readonly chain: sfn.Chain;

  constructor(scope: Construct, id: string, props: RecipientListProps) {
    super(scope, id);

    const lookup = tasks.DynamoGetItem.jsonata(this, "Fetch recipient list", {
      table: props.directory,
      key: { Type: tasks.DynamoAttributeValue.fromString(props.listKey) },
      // Unwrap DynamoDB's {"L":[{"S":"..."}]} envelope down to a list of plain strings.
      assign: { recipients: `{% $states.result.Item.${props.listAttribute}.L.S %}` },
    });

    // No ItemSelector. Under JSONPath you had to copy the whole document into every
    // iteration, because the item was all an iteration could see. Assigned variables are
    // visible inside the Map, so each iteration reads $request and $credit directly and
    // its input is just the recipient's name.
    const fanOut = sfn.Map.jsonata(this, "Fan out to recipients", {
      items: sfn.ProvideItems.jsonata("{% $recipients %}"),
      assign: { [props.resultVariable]: "{% $states.result %}" },
    }).itemProcessor(props.recipientTask);

    this.chain = sfn.Chain.start(lookup).next(fanOut);
  }
}

// ---------------------------------------------------------------------------
// Scatter-Gather (broadcast flavour) — publish once, let subscribers self-select.
// https://www.enterpriseintegrationpatterns.com/patterns/messaging/BroadcastAggregate.html
// ---------------------------------------------------------------------------

export interface ScatterGatherProps {
  readonly topic: sns.ITopic;
  /** JSONata object expression describing the request sent to every subscriber. */
  readonly request: string;
  /** How long to wait for the Aggregator to call back before giving up. */
  readonly timeout: Duration;
  /** Variable the aggregated result is assigned to. */
  readonly resultVariable: string;
}

/**
 * Publishes one request carrying a task token and parks the workflow until something
 * outside it calls SendTaskSuccess.
 *
 * The broker never learns who the recipients are, or how many there were. That is the
 * trade against `RecipientList`: total decoupling, at the cost of needing a correlation
 * identifier, somewhere to hold partial state, and an explicit completeness policy.
 */
export class ScatterGather extends Construct {
  public readonly task: tasks.SnsPublish;

  constructor(scope: Construct, id: string, props: ScatterGatherProps) {
    super(scope, id);

    this.task = tasks.SnsPublish.jsonata(this, "Publish request", {
      topic: props.topic,
      integrationPattern: sfn.IntegrationPattern.WAIT_FOR_TASK_TOKEN,
      message: sfn.TaskInput.fromObject({
        // The Return Address: how a responder gets back to this exact execution.
        taskToken: "{% $states.context.Task.Token %}",
        // The Correlation Identifier: which conversation a response belongs to.
        correlationId: "{% $states.context.Execution.Id %}",
        input: props.request,
      }),
      taskTimeout: sfn.Timeout.duration(props.timeout),
      assign: { [props.resultVariable]: "{% $states.result %}" },
    });
  }
}

// ---------------------------------------------------------------------------
// Aggregator — collect related messages and emit one result when complete.
// https://www.enterpriseintegrationpatterns.com/patterns/messaging/Aggregator.html
// ---------------------------------------------------------------------------

export interface AggregatorProps {
  /** Queue the individual responses arrive on. */
  readonly source: IQueue;
  /** Where partial aggregates live, keyed by correlation id. */
  readonly store: dynamodb.ITable;
  /** How many responses constitute "complete". */
  readonly completeAfter: number;
  readonly entry: string;
  readonly functionName?: string;
}

/**
 * A stateful collector that lives entirely outside the workflow.
 *
 * Its completeness condition ("two quotes") and the workflow's timeout ("five seconds")
 * together form the policy: whichever comes first wins. Neither component knows about
 * the other — they meet only at the task token.
 */
export class Aggregator extends Construct {
  public readonly handler: lambda.Function;

  constructor(scope: Construct, id: string, props: AggregatorProps) {
    super(scope, id);

    this.handler = new NodejsFunction(this, "Handler", {
      runtime: lambda.Runtime.NODEJS_22_X,
      handler: "handler",
      entry: props.entry,
      functionName: props.functionName,
      environment: {
        AGGREGATE_TABLE: props.store.tableName,
        COMPLETE_AFTER: String(props.completeAfter),
      },
    });

    this.handler.addEventSource(new SqsEventSource(props.source, { batchSize: 10 }));
    props.source.grantConsumeMessages(this.handler);
    props.store.grantReadWriteData(this.handler);
  }
}
