/**
    Each bank will vary its behavior by the following parameters:

    MIN_CREDIT_SCORE - the customer's minimum credit score required to receive a quote from this bank.
    MAX_LOAN_AMOUNT - the maximum amount the bank is willing to lend to a customer.
    BASE_RATE - the minimum rate the bank might give. The actual rate increases for a lower credit score and some randomness.
    BANK_ID - as the loan broker processes multiple responses, knowing which bank supplied the quote will be handy.
*/

function calcRate(amount, term, score, history) {
    if (amount <= process.env.MAX_LOAN_AMOUNT && score >= process.env.MIN_CREDIT_SCORE) {
        return parseFloat(process.env.BASE_RATE) + Math.random() * ((1000 - score) / 100.0);
    }
}

// ---------------------------------------------------------------------------
// FLOCI SHIM — the only deviation from the published AWS sample. See
// ../MODIFICATIONS.md.
//
// On AWS, this function's `onSuccess: EventBridgeDestination` carries its return
// value to MortgageQuotesEventBus. Floci 2.1.0 stores and provisions the event
// invoke config but does not apply it on async invoke, so the return value is
// dropped and the workflow always falls through to its 5-second timeout.
//
// When FLOCI_NO_LAMBDA_DESTINATIONS=1, we publish the same envelope AWS's
// destination would have produced, so FilterMortgageQuotesRule matches unchanged
// and nothing else in the sample has to know. Delete this block once Floci ships
// async destination routing.
// ---------------------------------------------------------------------------
const SHIM_ENABLED = process.env.FLOCI_NO_LAMBDA_DESTINATIONS === "1";

async function emitDestinationEvent(requestPayload, responsePayload, context) {
    const { EventBridgeClient, PutEventsCommand } = require("@aws-sdk/client-eventbridge");
    const events = new EventBridgeClient({});

    // The shape AWS puts on the bus for an OnSuccess EventBridge destination.
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
        responseContext: {
            statusCode: 200,
            executedVersion: "$LATEST",
        },
        responsePayload,
    };

    await events.send(
        new PutEventsCommand({
            Entries: [
                {
                    EventBusName: process.env.FLOCI_DESTINATION_EVENT_BUS || "MortgageQuotesEventBus",
                    Source: "lambda",
                    DetailType: "Lambda Function Invocation Result - Success",
                    Detail: JSON.stringify(detail),
                },
            ],
        })
    );
}
// --------------------------------------------------------------- end of shim

exports.handler = async (event, context) => {
    console.log("Received request for %s", process.env.BANK_ID);
    console.log("Received event:", JSON.stringify(event, null, 4));

    console.log(event.Records[0].Sns);
    const snsMessage = event.Records[0].Sns.Message;
    const msg = JSON.parse(snsMessage);
    console.debug(msg.input);

    const requestId = msg.context.Execution.Id;
    const taskToken = msg.taskToken;
    const bankId = process.env.BANK_ID;
    const data = msg.input;

    console.log("Loan Request over %d at credit score %d", data.Amount, data.Credit.Score);
    const rate = calcRate(data.Amount, data.Term, data.Credit.Score, data.Credit.History);

    if (rate) {
        const quote = {
            rate: rate,
            bankId: bankId,
            id: requestId,
            taskToken: taskToken,
        };
        console.log("Offering Loan", quote);

        if (SHIM_ENABLED) {
            await emitDestinationEvent(event, quote, context);
        }
        return quote;
    } else {
        console.log("Rejecting Loan");
    }
};
