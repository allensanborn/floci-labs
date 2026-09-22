/**
 * Aggregator. Collects bank quotes that arrive independently, groups them by correlation
 * id, and resumes the parked workflow once the completeness condition holds.
 *
 * Two upstream bugs are fixed here; both are described in ../../as-published/MODIFICATIONS.md.
 *
 *   1. `for (record of ...)` declared no binding. Harmless in a sloppy-mode CommonJS
 *      handler, a ReferenceError once esbuild emits strict-mode output — which is what
 *      NodejsFunction does, so upstream's aggregator throws on every single message.
 *
 *   2. `taskToken` was `var`-scoped across the loop, so a batch (batchSize: 10) resolved
 *      only the LAST record's token. With one execution in flight you never notice; with
 *      two, one of them hangs until its timeout. Here every record carries its own token
 *      and each correlation id is completed exactly once.
 */
const { DynamoDBClient, UpdateItemCommand } = require("@aws-sdk/client-dynamodb");
const { unmarshall } = require("@aws-sdk/util-dynamodb");
const { SFNClient, SendTaskSuccessCommand } = require("@aws-sdk/client-sfn");

const dynamodb = new DynamoDBClient({ apiVersion: "2012-08-10" });
const sfn = new SFNClient();

const AGGREGATE_TABLE = process.env.AGGREGATE_TABLE;
const COMPLETE_AFTER = parseInt(process.env.COMPLETE_AFTER || "2", 10);

/** Append one quote to this correlation id's aggregate and return the whole aggregate. */
const appendQuote = (correlationId, quote) =>
    new UpdateItemCommand({
        TableName: AGGREGATE_TABLE,
        Key: { Id: { S: correlationId } },
        UpdateExpression: "SET #quotes = list_append(if_not_exists(#quotes, :empty), :quote)",
        ExpressionAttributeNames: { "#quotes": "quotes" },
        ExpressionAttributeValues: {
            ":quote": { L: [{ M: { bankId: { S: quote.bankId }, rate: { N: String(quote.rate) } } }] },
            ":empty": { L: [] },
        },
        ReturnValues: "ALL_NEW",
    });

exports.handler = async (event) => {
    console.info("Aggregating %d record(s)", event.Records.length);

    // One entry per correlation id in this batch, so a batch spanning several executions
    // resumes each of them with its own token — exactly once.
    const completed = new Set();

    for (const record of event.Records) {
        const quote = JSON.parse(record.body);
        const { correlationId, taskToken } = quote;

        const response = await dynamodb.send(appendQuote(correlationId, quote));
        const aggregate = unmarshall(response.Attributes);
        const count = aggregate.quotes.length;
        console.info("%s now has %d quote(s)", correlationId, count);

        if (count < COMPLETE_AFTER || completed.has(correlationId)) continue;

        completed.add(correlationId);
        try {
            await sfn.send(new SendTaskSuccessCommand({
                taskToken,
                output: JSON.stringify(aggregate.quotes),
            }));
            console.info("%s complete — resumed the workflow", correlationId);
        } catch (error) {
            // Expected and benign once a workflow has already moved on: a late quote
            // arrives after the aggregate was completed, or after the task timed out.
            // The quote is still persisted; only the callback is refused.
            console.warn("%s could not be resumed (%s) — already completed or timed out",
                correlationId, error.name);
        }
    }
};
