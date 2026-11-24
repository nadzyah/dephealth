import { describe, expect, it } from "vitest";

import { RISK_BANDS, formatProbability, riskBand } from "./risk";

describe("riskBand", () => {
    it("puts a probability in the band its thresholds define", () => {
        expect(riskBand(RISK_BANDS.high)).toBe("high");
        expect(riskBand(0.97)).toBe("high");
        expect(riskBand(RISK_BANDS.medium)).toBe("medium");
        expect(riskBand(0.41)).toBe("medium");
        expect(riskBand(RISK_BANDS.medium - 0.001)).toBe("low");
        expect(riskBand(0)).toBe("low");
    });
});

describe("formatProbability", () => {
    it("keeps a figure under ten per cent to one decimal", () => {
        expect(formatProbability(0.031)).toBe("3.1%");
    });

    it("rounds a larger figure, where a decimal implies precision it lacks", () => {
        expect(formatProbability(0.971)).toBe("97%");
    });

    it("does not round a small probability away to nothing", () => {
        expect(formatProbability(0.004)).toBe("<1%");
    });

    it("shows a zero as zero, since it is a figure and not an absence", () => {
        expect(formatProbability(0)).toBe("0.0%");
    });
});
