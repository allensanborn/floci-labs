/**
 * Loan Broker — Recipient List (Hohpe, Part 2).
 *
 * https://www.enterpriseintegrationpatterns.com/ramblings/loanbroker_stepfunctions_recipient_list.html
 *
 * The workflow enriches the request with a credit score, reads the list of banks out of
 * DynamoDB, asks every bank on that list, and gathers the answers. The Map state *is*
 * the aggregator: it blocks until every iteration finishes.
 *
 * Written in JSONata with assigned variables rather than JSONPath with ResultPath
 * plumbing. The published sample threads one growing document through every state via
 * `resultPath`, so each state's output shape depends on every state before it. Here each
 * state assigns what it learned to a variable and the last state builds the response —
 * which is both AWS's current recommendation and much easier to read.
 */
import { CfnOutput, Duration, RemovalPolicy, Stack, StackProps } from "aws-cdk-lib";
import { Construct } from "constructs";
import * as dynamodb from "aws-cdk-lib/aws-dynamodb";
import * as lambda from "aws-cdk-lib/aws-lambda";
import * as logs from "aws-cdk-lib/aws-logs";
import * as sfn from "aws-cdk-lib/aws-stepfunctions";
import * as tasks from "aws-cdk-lib/aws-stepfunctions-tasks";
import * as path from "path";

import { RecipientList } from "./integration-patterns";
import { BANKS, BankConfig, fixedCreditScore, namePrefix } from "./banks";

export class RecipientListStack extends Stack {
  constructor(scope: Construct, id: string, props?: StackProps) {
    super(scope, id, props);

    const prefix = namePrefix();

    const creditBureau = new lambda.Function(this, "CreditBureau", {
      runtime: lambda.Runtime.NODEJS_22_X,
      handler: "app.handler",
      functionName: `${prefix}CreditBureau`,
      code: lambda.Code.fromAsset(path.join(__dirname, "..", "lambda", "credit-bureau")),
      environment: fixedCreditScore(),
    });

    const banks = BANKS.map((bank: BankConfig) =>
      new lambda.Function(this, `Bank${bank.id}`, {
        runtime: lambda.Runtime.NODEJS_22_X,
        handler: "app.handler",
        functionName: `${prefix}Bank${bank.id}`,
        code: lambda.Code.fromAsset(path.join(__dirname, "..", "lambda", "bank")),
        environment: {
          BANK_ID: bank.id,
          BASE_RATE: String(bank.baseRate),
          MAX_LOAN_AMOUNT: String(bank.maxLoanAmount),
          MIN_CREDIT_SCORE: String(bank.minCreditScore),
        },
      })
    );

    // The recipient list itself: data, not code. Adding a bank is a PutItem.
    const bankDirectory = new dynamodb.Table(this, "BankDirectory", {
      tableName: `${prefix}BankDirectory`,
      partitionKey: { name: "Type", type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      removalPolicy: RemovalPolicy.DESTROY,
    });

    // ---- the workflow -----------------------------------------------------

    const getCreditScore = tasks.LambdaInvoke.jsonata(this, "Get credit score", {
      lambdaFunction: creditBureau,
      payload: sfn.TaskInput.fromObject({
        SSN: "{% $states.input.SSN %}",
        // Correlation Identifier: the execution id ties every downstream call back to
        // this request. $states.context is JSONata's spelling of JSONPath's $$.
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

    // CDK cannot express "invoke the function this iteration names", because
    // LambdaInvoke wants an IFunction at synth time and the name only exists at runtime.
    // CustomState is the escape hatch — the same one the published sample reaches for.
    const askOneBank = new sfn.CustomState(this, "Ask one bank", {
      stateJson: {
        Type: "Task",
        Resource: "arn:aws:states:::lambda:invoke",
        Arguments: {
          // $states.input is this iteration's item: the bank's function name.
          // Everything else comes from variables assigned upstream — no per-item
          // document copying required.
          FunctionName: "{% $states.input %}",
          Payload: {
            SSN: "{% $request.SSN %}",
            Amount: "{% $request.Amount %}",
            Term: "{% $request.Term %}",
            Credit: "{% $credit %}",
          },
        },
        Output: "{% $states.result.Payload %}",
        End: true,
      },
    });

    const recipientList = new RecipientList(this, "AskEveryBank", {
      directory: bankDirectory,
      listKey: "Home",
      listAttribute: "BankAddress",
      recipientTask: askOneBank,
      resultVariable: "quotes",
    });

    // The article's Part 2 ends with a Pass that drops the banks which declined. The
    // published CDK sample never had it, so its output is littered with nulls. Restored.
    const buildResponse = sfn.Pass.jsonata(this, "Drop declined quotes", {
      outputs: `{% {
        "SSN": $request.SSN,
        "Amount": $request.Amount,
        "Term": $request.Term,
        "Credit": $credit,
        "Quotes": [ $quotes[$exists($.bankId)] ]
      } %}`,
    });

    const stateMachine = new sfn.StateMachine(this, "LoanBroker", {
      stateMachineName: `${prefix}LoanBroker-RecipientList`,
      queryLanguage: sfn.QueryLanguage.JSONATA,
      stateMachineType: sfn.StateMachineType.STANDARD,
      timeout: Duration.minutes(5),
      definitionBody: sfn.DefinitionBody.fromChainable(
        sfn.Chain.start(getCreditScore).next(recipientList.chain).next(buildResponse)
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

    banks.forEach((bank) => bank.grantInvoke(stateMachine));
    bankDirectory.grantReadData(stateMachine);

    new CfnOutput(this, "LoanBrokerArn", { value: stateMachine.stateMachineArn });
    new CfnOutput(this, "BankDirectoryTable", { value: bankDirectory.tableName });
  }
}
