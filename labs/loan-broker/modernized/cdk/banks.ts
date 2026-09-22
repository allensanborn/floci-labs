/**
 * Shared configuration for both topologies.
 *
 * Both stacks name their resources explicitly so you can read the emulator's inventory
 * and know what you are looking at. That means the names must not collide with the
 * `as-published/` track, which hardcodes `BankRecipientPawnshop`, `LoanBrokerBanksTable`
 * and friends — so everything here takes a prefix, and both tracks can be deployed at
 * the same time.
 */
export interface BankConfig {
  readonly id: string;
  readonly baseRate: number;
  readonly maxLoanAmount: number;
  readonly minCreditScore: number;
}

/**
 * Three banks with different appetites, so a single credit score produces a different
 * number of quotes depending on where it falls: below 400 nobody lends, 400-499 only
 * PawnShop, 500-599 adds Universal, 600+ all three.
 */
export const BANKS: BankConfig[] = [
  { id: "PawnShop", baseRate: 5, maxLoanAmount: 500_000, minCreditScore: 400 },
  { id: "Universal", baseRate: 4, maxLoanAmount: 700_000, minCreditScore: 500 },
  { id: "Premium", baseRate: 3, maxLoanAmount: 900_000, minCreditScore: 600 },
];

/** Prefix for every named resource. Override with LOAN_BROKER_PREFIX. */
export function namePrefix(): string {
  return process.env.LOAN_BROKER_PREFIX ?? "Modern";
}

/**
 * Pin the credit bureau's score so a run is reproducible.
 *
 * Unset, the bureau behaves exactly as the published sample does — a random score in
 * [300, 900) — and the number of quotes you get is luck. Set, the whole system becomes
 * deterministic, which is what lets this lab's README be a test rather than a demo.
 */
export function fixedCreditScore(): Record<string, string> {
  const score = process.env.FIXED_CREDIT_SCORE;
  return score ? { FIXED_CREDIT_SCORE: score } : {};
}
