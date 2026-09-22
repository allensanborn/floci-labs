/**
 * A bank, in the Pub-Sub topology: subscribed to the request topic, answers
 * asynchronously. Its return value is carried to the event bus by the function's
 * onSuccess destination — the bank itself knows nothing about the bus, the queue or the
 * aggregator. That decoupling is the point of the pattern.
 */
function calcRate(amount, term, score, history) {
    const maxAmount = parseInt(process.env.MAX_LOAN_AMOUNT, 10);
    const minScore = parseInt(process.env.MIN_CREDIT_SCORE, 10);
    if (amount <= maxAmount && score >= minScore) {
        return parseFloat(process.env.BASE_RATE) + Math.random() * ((1000 - score) / 100.0);
    }
    return undefined;
}

// --- Floci shim -------------------------------------------------------------
// Floci 2.1.0 stores a function's onSuccess destination but does not apply it on async
// invoke, so the return value below goes nowhere. With FLOCI_NO_LAMBDA_DESTINATIONS=1 we
// publish the envelope AWS would have published, and the EventBridge rule matches
// unchanged. Fixed on floci feat/lambda-async-invoke-destinations; delete this then.
// See ../../README.md → "The one gap".
const SHIM = process.env.FLOCI_NO_LAMBDA_DESTINATIONS === "1";

async function publishAsDestinationWould(requestPayload, responsePayload, context) {
    const { EventBridgeClient, PutEventsCommand } = require("@aws-sdk/client-eventbridge");
    const detail = {
        version: "1.0",
        timestamp: new Date().toISOString(),
        requestContext: {
            requestId: context.awsRequestId,
            functionArn: context.invokedFunctionArn,
            condition: "Success",
            approximateInvokeCount: 1,
        },
        requestPayload,
        responseContext: { statusCode: 200, executedVersion: "$LATEST" },
        responsePayload,
    };
    await new EventBridgeClient({}).send(
        new PutEventsCommand({
            Entries: [{
                EventBusName: process.env.QUOTE_EVENT_BUS,
                Source: "lambda",
                DetailType: "Lambda Function Invocation Result - Success",
                Detail: JSON.stringify(detail),
            }],
        })
    );
}
// --- end shim ---------------------------------------------------------------

exports.handler = async (event, context) => {
    const request = JSON.parse(event.Records[0].Sns.Message);
    const { Amount: amount, Term: term, Credit: credit } = request.input;

    const rate = calcRate(amount, term, credit.Score, credit.History);
    if (rate === undefined) {
        console.log("%s declines: score %d, amount %d", process.env.BANK_ID, credit.Score, amount);
        return null;
    }

    const quote = {
        rate,
        bankId: process.env.BANK_ID,
        // Correlation Identifier and Return Address travel with the quote, so the
        // aggregator can both group it and resume the right execution.
        correlationId: request.correlationId,
        taskToken: request.taskToken,
    };
    console.log("%s offers %f", process.env.BANK_ID, rate);

    if (SHIM) await publishAsDestinationWould(event, quote, context);
    return quote;
};
