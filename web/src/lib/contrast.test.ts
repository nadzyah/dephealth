import { describe, expect, it } from "vitest";

import { contrastRatio, luminance } from "./contrast";

describe("contrast", () => {
    it("holds black against white at the maximum ratio", () => {
        expect(contrastRatio("#000000", "#ffffff")).toBeCloseTo(21, 5);
    });

    // A production build shortens #ffffff to #fff, and the page reads the
    // computed value rather than the source, so both forms have to parse
    it.each([
        ["#fff", "#ffffff"],
        ["#FFF", "#ffffff"],
        ["#1a5", "#11aa55"],
        ["#ffff", "#ffffff"],
        ["#1a5490ff", "#1a5490"],
    ])("reads %s as %s", (short, long) => {
        expect(luminance(short)).toBeCloseTo(luminance(long), 10);
    });

    it("is symmetric", () => {
        expect(contrastRatio("#1a5490", "#ffffff")).toBeCloseTo(
            contrastRatio("#ffffff", "#1a5490"),
            10,
        );
    });
});
