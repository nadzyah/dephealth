import type { ReactNode } from "react";
import { NavLink } from "react-router-dom";

import { ExternalLink } from "../ui/ExternalLink";
import { BookIcon, PaletteIcon, TreeIcon, UploadIcon } from "../ui/icons";
import { Appearance } from "./Appearance";
import { Notices } from "./Notices";

import "./AppShell.css";

/**
 * The navigation is the same list in both places: a row in the header from
 * tablet width up, and a bar at the bottom of a phone, where it sits under the
 * thumb and follows the platform pattern. One is hidden at each width, so the
 * main navigation is reachable on every device.
 */
const destinations = [
    { to: "/", label: "Assess", icon: UploadIcon, end: true },
    { to: "/packages", label: "Packages", icon: TreeIcon, end: false },
    { to: "/method", label: "Method", icon: BookIcon, end: false },
    { to: "/design-system", label: "Design", icon: PaletteIcon, end: false },
];

export function AppShell({ children }: { children: ReactNode }) {
    return (
        <div className="app">
            <a className="skip-link" href="#main">
                Skip to content
            </a>

            <header className="app-header">
                <div className="container app-header-inner">
                    <NavLink to="/" className="brand">
                        <span className="brand-mark" aria-hidden="true" />
                        <span>dephealth</span>
                    </NavLink>

                    <nav className="primary-nav" aria-label="Primary">
                        {destinations.map(({ to, label, end }) => (
                            <NavLink key={to} to={to} end={end} className="nav-link touchable">
                                {label}
                            </NavLink>
                        ))}
                    </nav>

                    <Appearance />
                </div>
            </header>

            <main id="main" className="content">
                <div className="container">{children}</div>
            </main>

            <footer className="app-footer">
                <div className="container row between small muted">
                    <span>
                        Adoption forecasts and maintenance risk for Cargo dependencies. Diploma
                        project, European Humanities University.
                    </span>
                    <ExternalLink href="https://github.com/nadzyah/dephealth">Source</ExternalLink>
                </div>
            </footer>

            <nav className="bottom-nav" aria-label="Primary">
                {destinations.map(({ to, label, icon: Icon, end }) => (
                    <NavLink key={to} to={to} end={end} className="bottom-nav-link">
                        <Icon />
                        <span>{label}</span>
                    </NavLink>
                ))}
            </nav>

            <Notices />
        </div>
    );
}
