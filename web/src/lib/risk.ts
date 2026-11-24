/**
 * How a probability is turned into words and a figure. Here rather than in the
 * badge that renders it, so it can be read and tested without a DOM.
 */

export type RiskBand = "high" | "medium" | "low";

/**
 * Where the bands fall is a presentation choice, not a property of the model,
 * which is why the figure is always shown beside the word.
 */
export const RISK_BANDS = { high: 0.5, medium: 0.2 } as const;

export function riskBand(probability: number): RiskBand {
    if (probability >= RISK_BANDS.high) return "high";
    if (probability >= RISK_BANDS.medium) return "medium";
    return "low";
}

export const bandLabel: Record<RiskBand, string> = {
    high: "high",
    medium: "moderate",
    low: "low",
};

/**
 * A probability as a percentage. One decimal under ten per cent, where it
 * carries information, and none above it, where it would imply a precision the
 * model does not have. A figure that would round to nothing is shown as under
 * one per cent rather than as zero, since zero means something else.
 */
export function formatProbability(probability: number): string {
    const percent = probability * 100;
    if (percent > 0 && percent < 1) return "<1%";
    return `${percent.toFixed(percent < 10 ? 1 : 0)}%`;
}
