/**
 * A link that leaves the application. It opens in a new tab, which keeps the
 * report the reader is holding open behind it, and says so in the accessible
 * name rather than only in an icon, since a new tab is a change of context a
 * reader should be told about before following it.
 */

import type { ReactNode } from "react";

import "./ExternalLink.css";

interface ExternalLinkProps {
    href: string;
    children: ReactNode;
    className?: string;
}

export function ExternalLink({ href, children, className }: ExternalLinkProps) {
    return (
        <a
            href={href}
            target="_blank"
            // noopener keeps the new page from reaching this one through
            // window.opener, and noreferrer withholds the address it came from
            rel="noopener noreferrer"
            className={["external-link", className].filter(Boolean).join(" ")}
        >
            {children}
            <svg
                className="external-link-mark"
                width="0.75em"
                height="0.75em"
                viewBox="0 0 16 16"
                fill="none"
                stroke="currentColor"
                strokeWidth="1.8"
                strokeLinecap="round"
                strokeLinejoin="round"
                aria-hidden="true"
            >
                <path d="M6.5 3H3v10h10V9.5" />
                <path d="M9.5 2.5H13.5V6.5" />
                <path d="M13.5 2.5L7.5 8.5" />
            </svg>
            <span className="visually-hidden">(opens in a new tab)</span>
        </a>
    );
}
