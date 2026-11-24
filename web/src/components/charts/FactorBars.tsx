/**
 * What moved a risk score, as bars either side of zero. Polarity, so a diverging
 * pair with a neutral baseline between them.
 *
 * Colour is never the only carrier of the direction. Each row states it in
 * words, the sign is in the number, and the bar sits left or right of the
 * baseline, which is what keeps the chart readable for a reader who cannot tell
 * the two hues apart.
 */

import type { Factor } from "../../api/types";

import "./FactorBars.css";

const value = new Intl.NumberFormat("en", { maximumFractionDigits: 2 });
const signed = new Intl.NumberFormat("en", {
    maximumFractionDigits: 2,
    signDisplay: "always",
});

export function FactorBars({ factors }: { factors: Factor[] }) {
    if (factors.length === 0) {
        return (
            <p className="muted small">
                No factor decomposition was stored for this entry, which is the case for an entry
                that carries no score.
            </p>
        );
    }

    const widest = Math.max(...factors.map((factor) => Math.abs(factor.contribution)));

    return (
        <ul className="factor-bars">
            {factors.map((factor) => {
                const share = widest === 0 ? 0 : (Math.abs(factor.contribution) / widest) * 100;
                const raised = factor.contribution > 0;

                return (
                    <li className="factor" key={factor.code}>
                        <div className="factor-head">
                            <span className="factor-label" title={factor.description}>
                                {factor.label}
                            </span>
                            <span className="factor-observed muted small numeric">
                                {value.format(factor.observed_value)}
                            </span>
                        </div>

                        <div className="factor-track">
                            <span className="factor-baseline" aria-hidden="true" />
                            <span
                                className={`factor-bar ${raised ? "raised" : "lowered"}`}
                                style={{ width: `${share / 2}%` }}
                                aria-hidden="true"
                            />
                        </div>

                        <div className="factor-foot small">
                            <span className={raised ? "raised-text" : "lowered-text"}>
                                {factor.direction}
                            </span>
                            <span className="numeric muted">
                                {signed.format(factor.contribution)}
                            </span>
                        </div>
                    </li>
                );
            })}
        </ul>
    );
}
