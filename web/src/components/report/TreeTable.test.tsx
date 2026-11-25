import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import { describe, expect, it } from "vitest";

import type { ReportEntry } from "../../api/types";
import { TreeTable } from "./TreeTable";

const entries: ReportEntry[] = [
    {
        ordinal: 1,
        package_name: "failure",
        package_version: "0.1.8",
        depth: 1,
        relation: "indirect",
        resolved: true,
        risk: { probability: 0.971, horizon_days: 365 },
        forecast: { point_downloads: 12258, horizon_months: 12, insufficient_history: false },
        activity: {
            distinct_contributors: 0,
            days_since_last_event: 1920,
            contributor_count_withheld: false,
        },
    },
    {
        ordinal: 2,
        package_name: "serde",
        package_version: "1.0.228",
        depth: 0,
        relation: "direct",
        resolved: true,
        risk: { probability: 0.031, horizon_days: 365 },
        forecast: { point_downloads: 41203371, horizon_months: 12, insufficient_history: false },
        activity: {
            distinct_contributors: 42,
            days_since_last_event: 2,
            contributor_count_withheld: false,
        },
    },
    {
        ordinal: 3,
        package_name: "local-helper",
        package_version: "0.1.0",
        depth: 0,
        relation: "direct",
        resolved: false,
        unresolved: {
            reason: "not_a_registry_package",
            label: "Not published on the registry",
            remedy: "The entry is a path or git dependency.",
        },
    },
];

function renderTable() {
    return render(
        <MemoryRouter>
            <TreeTable entries={entries} token="demo" />
        </MemoryRouter>,
    );
}

function rowNames(): string[] {
    const rows = screen.getAllByRole("row").slice(1); // the header row is first
    return rows.map((row) => within(row).getAllByRole("cell")[1].textContent ?? "");
}

describe("TreeTable", () => {
    it("shows the stored ranking by default", () => {
        renderTable();

        expect(rowNames()[0]).toContain("failure");
        expect(rowNames()[2]).toContain("local-helper");
        expect(screen.getByText("3 entries")).toBeInTheDocument();
    });

    it("links a scored entry to its evidence and leaves an unscored one as text", () => {
        renderTable();

        expect(screen.getByRole("link", { name: "failure" })).toHaveAttribute(
            "href",
            "/r/demo/p/failure",
        );
        expect(screen.queryByRole("link", { name: "local-helper" })).not.toBeInTheDocument();
    });

    it("narrows the rows to a search and says how many are left", async () => {
        renderTable();

        await userEvent.type(screen.getByLabelText(/search the tree/i), "serde");

        expect(rowNames()).toHaveLength(1);
        expect(rowNames()[0]).toContain("serde");
        expect(screen.getByText("1 of 3 entries")).toBeInTheDocument();
    });

    it("filters to the entries that carry no score", async () => {
        renderTable();

        await userEvent.click(screen.getByRole("radio", { name: "Unresolved" }));

        expect(rowNames()).toHaveLength(1);
        expect(rowNames()[0]).toContain("local-helper");
        expect(screen.getByText("Not published on the registry")).toBeInTheDocument();
    });

    it("filters to the direct dependencies", async () => {
        renderTable();

        await userEvent.click(screen.getByRole("radio", { name: "Direct Only" }));

        expect(rowNames()).toHaveLength(2);
        expect(rowNames().every((name) => !name.includes("failure"))).toBe(true);
    });

    it("sorts by name and reverses on a second press", async () => {
        renderTable();
        const header = screen.getByRole("button", { name: /package/i });

        await userEvent.click(header);
        expect(rowNames()[0]).toContain("failure");
        expect(rowNames()[2]).toContain("serde");

        await userEvent.click(header);
        expect(rowNames()[0]).toContain("serde");
    });

    it("sorts an unscored entry last whichever way the risk column points", async () => {
        renderTable();
        const header = screen.getByRole("button", { name: /risk/i });

        await userEvent.click(header);
        expect(rowNames()[2]).toContain("local-helper");

        await userEvent.click(header);
        expect(rowNames()[2]).toContain("local-helper");
    });

    it("tells the assistive layer which column is sorted", async () => {
        renderTable();

        await userEvent.click(screen.getByRole("button", { name: /depth/i }));

        const header = screen.getByRole("columnheader", { name: /depth/i });
        expect(header).toHaveAttribute("aria-sort", "ascending");
    });

    it("says so when nothing matches", async () => {
        renderTable();

        await userEvent.type(screen.getByLabelText(/search the tree/i), "nothing-like-this");

        expect(screen.getByText(/nothing matches/i)).toBeInTheDocument();
    });
});
