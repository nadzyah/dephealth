/**
 * WCAG 2.1 level AA holds body text to 4.5:1 against its background, and the
 * edge of a control to 3:1. These are the numbers, so a palette change that
 * breaks them fails the suite instead of reaching a reader.
 */

import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

import { contrastRatio } from "../lib/contrast";

// Read from disk rather than imported, because Vitest does not run the CSS
// pipeline and a stylesheet import comes back empty. Vitest runs from the
// project root.
const css = readFileSync("src/styles/tokens.css", "utf8");

function tokensOf(selector: string): Record<string, string> {
    const start = css.indexOf(selector);
    if (start < 0) throw new Error(`no ${selector} block in tokens.css`);

    const open = css.indexOf("{", start);
    const close = css.indexOf("}", open);
    const body = css.slice(open, close);

    const tokens: Record<string, string> = {};
    for (const [, name, value] of body.matchAll(/--([\w-]+):\s*(#[0-9a-f]{6})/gi)) {
        tokens[name] = value;
    }
    return tokens;
}

const ratio = contrastRatio;

const themes = {
    light: tokensOf(":root {"),
    dark: tokensOf(':root[data-theme="dark"]'),
};

const textTokens = [
    "color-text",
    "color-text-muted",
    "color-accent",
    "color-risk-high",
    "color-risk-medium",
    "color-risk-low",
];

describe.each(Object.entries(themes))("%s theme", (name, tokens) => {
    it("defines every token the components use", () => {
        for (const token of [...textTokens, "color-surface", "color-surface-raised"]) {
            expect(tokens[token], `${token} in the ${name} theme`).toMatch(/^#[0-9a-f]{6}$/i);
        }
    });

    it.each(textTokens)("reads at 4.5:1 or better, %s on both surfaces", (token) => {
        for (const surface of ["color-surface", "color-surface-raised"]) {
            const measured = ratio(tokens[token], tokens[surface]);
            expect(
                Number(measured.toFixed(2)),
                `${token} on ${surface} in the ${name} theme`,
            ).toBeGreaterThanOrEqual(4.5);
        }
    });

    it("keeps the text on an accent button readable", () => {
        expect(
            ratio(tokens["color-accent"], tokens["color-accent-contrast"]),
        ).toBeGreaterThanOrEqual(4.5);
    });

    it("draws the edge of a control at 3:1 or better", () => {
        expect(
            ratio(tokens["color-border-strong"], tokens["color-surface"]),
        ).toBeGreaterThanOrEqual(3);
    });

    // A mark is not text, so WCAG 1.4.11 applies rather than 1.4.3. Separation
    // between the two diverging marks is the palette validator's business
    it.each(["chart-series", "chart-positive", "chart-negative"])(
        "draws %s at 3:1 or better against the surface",
        (token) => {
            expect(ratio(tokens[token], tokens["color-surface"])).toBeGreaterThanOrEqual(3);
        },
    );
});
