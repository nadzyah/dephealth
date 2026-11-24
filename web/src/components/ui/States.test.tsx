import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { Empty, Failure } from "./States";
import { ApiProblem } from "../../api/problem";

const problem = new ApiProblem({
    type: "/problems/report-not-found",
    title: "No such report",
    status: 404,
    detail: "A token cannot be recovered once it is lost.",
});

describe("a state heading", () => {
    it("sits under a card heading by default", () => {
        render(<Empty title="Nothing matches" />);
        expect(screen.getByRole("heading", { level: 3, name: "Nothing matches" })).toBeVisible();
    });

    it("becomes the first heading when the state is the whole screen", () => {
        render(<Failure problem={problem} level={1} />);

        expect(screen.getByRole("heading", { level: 1, name: "No such report" })).toBeVisible();

        // A screen whose only heading is an h3 leaves a reader navigating by
        // heading with no entry point, which is what the level is for
        expect(screen.queryByRole("heading", { level: 3 })).toBeNull();
    });

    it("announces a failure without waiting for focus", () => {
        render(<Failure problem={problem} level={1} />);
        expect(screen.getByRole("alert")).toHaveTextContent("No such report");
    });
});
