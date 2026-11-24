import type { ReactNode } from "react";

import { bandLabel, formatProbability, riskBand } from "../../lib/risk";

import "./Badge.css";

export type BadgeTone = "neutral" | "accent" | "high" | "medium" | "low";

interface BadgeProps {
    tone?: BadgeTone;
    children: ReactNode;
    className?: string;
}

export function Badge({ tone = "neutral", children, className }: BadgeProps) {
    return <span className={["badge", tone, className].filter(Boolean).join(" ")}>{children}</span>;
}

interface RiskBadgeProps {
    probability: number | null | undefined;
    horizonDays?: number | null;
}

/**
 * The figure, the band and the horizon. A reader with assistive technology gets
 * one sentence; everyone else gets the number beside the word, so the colour is
 * never the only thing carrying the band.
 */
export function RiskBadge({ probability, horizonDays }: RiskBadgeProps) {
    if (probability === null || probability === undefined) {
        return <Badge tone="neutral">not scored</Badge>;
    }

    const band = riskBand(probability);
    const horizon = horizonDays ? ` within ${horizonDays} days` : "";

    return (
        <Badge tone={band}>
            <span className="visually-hidden">
                {`Risk that maintenance ceases${horizon}: ${formatProbability(probability)}, ${bandLabel[band]}`}
            </span>
            <span aria-hidden="true" className="numeric">
                {formatProbability(probability)}
            </span>
            <span aria-hidden="true" className="badge-band">
                {bandLabel[band]}
            </span>
        </Badge>
    );
}
