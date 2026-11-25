/**
 * Links to the rest of the About section, shown on each of its pages.
 *
 * The menu in the header is not the only way in: Method is reached from a
 * report by "Learn more", and a reader who arrives that way would otherwise
 * never see that the other two exist.
 */

import { NavLink } from "react-router-dom";

import { aboutPages } from "./about";

import "./SectionNav.css";

export function SectionNav() {
    return (
        <nav className="section-nav" aria-label="About">
            {aboutPages.map(({ to, label }) => (
                <NavLink key={to} to={to} className="section-nav-link touchable">
                    {label}
                </NavLink>
            ))}
        </nav>
    );
}
