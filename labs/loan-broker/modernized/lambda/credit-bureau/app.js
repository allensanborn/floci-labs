/**
 * Credit bureau. Enriches a loan request with a credit score.
 *
 * Difference from the published sample: the score can be pinned, per deployment
 * (FIXED_CREDIT_SCORE) or per request (ForceScore). Upstream returns a random
 * score in [300, 900), which makes every downstream assertion a coin flip — each bank
 * has its own MIN_CREDIT_SCORE, so the same input yields three quotes, one, or none.
 * Fine for a demo you watch; useless for a README that has to pass in CI. Leave the env
 * var unset and the behaviour is exactly upstream's.
 */
const getRandomInt = (min, max) => min + Math.floor(Math.random() * (max - min));

const MIN_SCORE = 300;
const MAX_SCORE = 900;
const SSN_PATTERN = /^\d{3}-\d{2}-\d{4}$/;

/**
 * Score precedence: what this request asked for, then what the deployment pinned, then
 * random (upstream's behaviour). The per-request override is what lets one deployment
 * demonstrate both the callback path and the timeout path without a redeploy.
 */
const creditScore = (event) => {
    if (event.ForceScore) return parseInt(event.ForceScore, 10);
    const fixed = process.env.FIXED_CREDIT_SCORE;
    return fixed ? parseInt(fixed, 10) : getRandomInt(MIN_SCORE, MAX_SCORE);
};

exports.handler = async (event) => {
    if (!SSN_PATTERN.test(event.SSN)) {
        return { statusCode: 400, request_id: event.RequestId, body: { SSN: event.SSN } };
    }
    return {
        statusCode: 200,
        request_id: event.RequestId,
        body: { SSN: event.SSN, score: creditScore(event), history: getRandomInt(1, 30) },
    };
};
