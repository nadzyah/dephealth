import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { RiskBadge } from "./Badge";

describe("RiskBadge", () => {
    it("states the figure, the band and the horizon for a screen reader", () => {
        render(<RiskBadge probability={0.971} horizonDays={365} />);

        expect(
            screen.getByText("Risk that maintenance ceases within 365 days: 97%, high"),
        ).toBeInTheDocument();
    });

    it("shows the figure beside the word, so colour is never the only carrier", () => {
        render(<RiskBadge probability={0.412} horizonDays={365} />);

        expect(screen.getByText("41%")).toBeInTheDocument();
        expect(screen.getByText("moderate")).toBeInTheDocument();
    });

    it("says an entry is not scored rather than implying a low risk", () => {
        render(<RiskBadge probability={null} />);

        expect(screen.getByText("not scored")).toBeInTheDocument();
        expect(screen.queryByText("0%")).not.toBeInTheDocument();
    });

    it("leaves the horizon out when there is none to state", () => {
        render(<RiskBadge probability={0.5} />);

        expect(screen.getByText("Risk that maintenance ceases: 50%, high")).toBeInTheDocument();
    });
});
