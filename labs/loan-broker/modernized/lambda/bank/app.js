/**
 * A bank, in the Recipient List topology: invoked directly by the workflow, returns its
 * quote synchronously.
 *
 *   MIN_CREDIT_SCORE  lowest credit score this bank will lend to
 *   MAX_LOAN_AMOUNT   most this bank will lend
 *   BASE_RATE         floor rate; the offer rises as the credit score falls
 *   BANK_ID           which bank a quote came from
 */
function calcRate(amount, term, score, history) {
    const maxAmount = parseInt(process.env.MAX_LOAN_AMOUNT, 10);
    const minScore = parseInt(process.env.MIN_CREDIT_SCORE, 10);
    if (amount <= maxAmount && score >= minScore) {
        return parseFloat(process.env.BASE_RATE) + Math.random() * ((1000 - score) / 100.0);
    }
    return undefined;
}

exports.handler = async (event) => {
    const { Amount: amount, Term: term, Credit: credit } = event;
    const rate = calcRate(amount, term, credit.Score, credit.History);
    if (rate === undefined) {
        console.log("%s declines: score %d, amount %d", process.env.BANK_ID, credit.Score, amount);
        return null;
    }
    console.log("%s offers %f", process.env.BANK_ID, rate);
    return { rate, bankId: process.env.BANK_ID };
};
