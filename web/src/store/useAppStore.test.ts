import { beforeEach, describe, expect, it } from "vitest";

import { selectNotices, selectRecent, useAppStore, type RecentReport } from "./useAppStore";

const report = (token: string, project?: string): RecentReport => ({
    token,
    assessedOn: "2026-11-25",
    entries: 39,
    project,
});

beforeEach(() => {
    useAppStore.setState({ theme: "system", textScale: 1, notices: [], recent: [] });
    localStorage.clear();
});

describe("appearance", () => {
    it("holds the reader's choices", () => {
        useAppStore.getState().setTheme("dark");
        useAppStore.getState().setTextScale(1.25);

        expect(useAppStore.getState().theme).toBe("dark");
        expect(useAppStore.getState().textScale).toBe(1.25);
    });
});

describe("notices", () => {
    it("returns the identifier that dismisses the notice it raised", () => {
        const id = useAppStore.getState().notify({ kind: "success", title: "Assessment stored" });

        expect(selectNotices(useAppStore.getState())).toHaveLength(1);

        useAppStore.getState().dismiss(id);
        expect(selectNotices(useAppStore.getState())).toHaveLength(0);
    });

    it("dismisses one notice and leaves the rest", () => {
        const first = useAppStore.getState().notify({ kind: "info", title: "First" });
        useAppStore.getState().notify({ kind: "error", title: "Second" });

        useAppStore.getState().dismiss(first);

        const left = selectNotices(useAppStore.getState());
        expect(left).toHaveLength(1);
        expect(left[0].title).toBe("Second");
    });
});

describe("recent reports", () => {
    it("puts the newest first and holds each link once", () => {
        useAppStore.getState().remember(report("a", "my-service"));
        useAppStore.getState().remember(report("b"));
        useAppStore.getState().remember(report("a", "my-service"));

        const recent = selectRecent(useAppStore.getState());
        expect(recent.map((held) => held.token)).toEqual(["a", "b"]);
    });

    it("keeps the five most recent and forgets the sixth", () => {
        for (const token of ["1", "2", "3", "4", "5", "6"]) {
            useAppStore.getState().remember(report(token));
        }

        const recent = selectRecent(useAppStore.getState());
        expect(recent).toHaveLength(5);
        expect(recent.map((held) => held.token)).toEqual(["6", "5", "4", "3", "2"]);
    });

    it("forgets every link at once", () => {
        useAppStore.getState().remember(report("a"));
        useAppStore.getState().forgetAll();

        expect(selectRecent(useAppStore.getState())).toHaveLength(0);
    });
});

describe("what survives a reload", () => {
    // A notice about a request that has already finished is noise on the next
    // visit, so it is the one part of the store that is not persisted
    it("persists the appearance and the links, and not the notices", () => {
        useAppStore.getState().setTheme("light");
        useAppStore.getState().remember(report("a", "my-service"));
        useAppStore.getState().notify({ kind: "error", title: "Something failed" });

        const stored = JSON.parse(localStorage.getItem("dephealth.preferences") ?? "{}");

        expect(stored.state.theme).toBe("light");
        expect(stored.state.recent).toHaveLength(1);
        expect(stored.state.notices).toBeUndefined();
    });
});
