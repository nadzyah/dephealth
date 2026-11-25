/**
 * The screens that describe the project rather than act on a lockfile. The same
 * list is the About menu in the navigation and the row at the top of each of
 * these pages, so the three stay reachable from one another.
 */

export interface AboutPage {
    to: string;
    label: string;
}

export const aboutPages: AboutPage[] = [
    { to: "/about", label: "Overview" },
    { to: "/method", label: "Method" },
    { to: "/design-system", label: "Design System" },
];
