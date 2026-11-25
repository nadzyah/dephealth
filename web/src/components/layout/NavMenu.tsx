/**
 * The group in the navigation that holds the screens describing the project
 * rather than acting on a lockfile.
 *
 * A details element rather than a custom menu, so it opens with the keyboard
 * and needs no focus trapping. What details does not do by itself is close
 * again once the reader has moved on, so a pointer landing outside it, Escape
 * and a followed link each close it here.
 */

import { useEffect, useRef } from "react";
import { NavLink, useLocation } from "react-router-dom";

import { BookIcon, ChevronDownIcon } from "../ui/icons";

import "./NavMenu.css";

export interface NavMenuItem {
    to: string;
    label: string;
}

interface NavMenuProps {
    label: string;
    items: NavMenuItem[];
    /** The header row, or the bar at the bottom of a phone. */
    variant: "header" | "bar";
}

export function NavMenu({ label, items, variant }: NavMenuProps) {
    const details = useRef<HTMLDetailsElement>(null);
    const { pathname } = useLocation();

    const holdsCurrent = items.some(
        (item) => pathname === item.to || pathname.startsWith(`${item.to}/`),
    );

    useEffect(() => {
        function onPointerDown(event: PointerEvent) {
            const element = details.current;
            if (element?.open && !element.contains(event.target as Node)) element.open = false;
        }

        function onKeyDown(event: KeyboardEvent) {
            const element = details.current;
            if (event.key !== "Escape" || !element?.open) return;
            element.open = false;
            element.querySelector("summary")?.focus();
        }

        document.addEventListener("pointerdown", onPointerDown);
        document.addEventListener("keydown", onKeyDown);
        return () => {
            document.removeEventListener("pointerdown", onPointerDown);
            document.removeEventListener("keydown", onKeyDown);
        };
    }, []);

    const summaryClass = [
        variant === "header" ? "nav-link touchable" : "bottom-nav-link",
        holdsCurrent ? "active" : "",
    ]
        .filter(Boolean)
        .join(" ");

    return (
        <details className={`nav-menu nav-menu-${variant}`} ref={details}>
            <summary className={summaryClass}>
                {variant === "bar" && <BookIcon />}
                <span>{label}</span>
                {variant === "header" && <ChevronDownIcon className="nav-menu-mark" size="1em" />}
            </summary>

            <div className="nav-menu-panel">
                {items.map((item) => (
                    <NavLink
                        key={item.to}
                        to={item.to}
                        className="nav-menu-item"
                        onClick={() => {
                            if (details.current) details.current.open = false;
                        }}
                    >
                        {item.label}
                    </NavLink>
                ))}
            </div>
        </details>
    );
}
