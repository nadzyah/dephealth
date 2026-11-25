/**
 * The global store. Three things belong here and nothing else does: what the
 * reader has chosen about appearance, the notices any screen may raise, and the
 * links this browser has opened before.
 *
 * Everything else is local state in the screen that owns it. A store is for
 * state that outlives the component that set it or is read somewhere unrelated,
 * and report data is neither: it is fetched by the screen that shows it.
 *
 * Appearance and the recent links are persisted, so a reader who sets dark and
 * a larger text size finds them next time. Notices are not, since a notice
 * about a request that has finished is noise on the next visit.
 */

import { create } from "zustand";
import { persist } from "zustand/middleware";

export type ThemeChoice = "system" | "light" | "dark";

/** A step of the type scale, applied to the root font size. */
export type TextScale = 1 | 1.125 | 1.25;

export type NoticeKind = "error" | "success" | "info";

export interface Notice {
    id: string;
    kind: NoticeKind;
    title: string;
    detail?: string;
}

export interface RecentReport {
    token: string;
    assessedOn: string;
    entries: number;
    /** The submitting project, when the lockfile named one. */
    project?: string;
}

interface AppState {
    theme: ThemeChoice;
    textScale: TextScale;
    notices: Notice[];
    recent: RecentReport[];

    setTheme: (theme: ThemeChoice) => void;
    setTextScale: (scale: TextScale) => void;
    notify: (notice: Omit<Notice, "id">) => string;
    dismiss: (id: string) => void;
    remember: (report: RecentReport) => void;
    forgetAll: () => void;
}

const RECENT_LIMIT = 5;

export const useAppStore = create<AppState>()(
    persist(
        (set) => ({
            theme: "system",
            textScale: 1,
            notices: [],
            recent: [],

            setTheme: (theme) => set({ theme }),

            setTextScale: (textScale) => set({ textScale }),

            notify: (notice) => {
                const id = crypto.randomUUID();
                set((state) => ({ notices: [...state.notices, { ...notice, id }] }));
                return id;
            },

            dismiss: (id) =>
                set((state) => ({ notices: state.notices.filter((notice) => notice.id !== id) })),

            remember: (report) =>
                set((state) => ({
                    recent: [
                        report,
                        ...state.recent.filter((held) => held.token !== report.token),
                    ].slice(0, RECENT_LIMIT),
                })),

            forgetAll: () => set({ recent: [] }),
        }),
        {
            name: "dephealth.preferences",
            partialize: (state) => ({
                theme: state.theme,
                textScale: state.textScale,
                recent: state.recent,
            }),
        },
    ),
);

/* Selectors, so a component subscribes to one field and does not re-render when
   an unrelated one changes. */

export const selectTheme = (state: AppState) => state.theme;
export const selectTextScale = (state: AppState) => state.textScale;
export const selectNotices = (state: AppState) => state.notices;
export const selectRecent = (state: AppState) => state.recent;
