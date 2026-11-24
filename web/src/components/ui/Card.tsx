import type { ReactNode } from "react";

import "./Card.css";

interface CardProps {
    title?: ReactNode;
    /** Sits opposite the title, for a link or a control. */
    action?: ReactNode;
    footer?: ReactNode;
    children: ReactNode;
    className?: string;
}

export function Card({ title, action, footer, children, className }: CardProps) {
    return (
        <section className={["card", className].filter(Boolean).join(" ")}>
            {(title || action) && (
                <header className="card-head">
                    {title && <h2 className="card-title">{title}</h2>}
                    {action}
                </header>
            )}
            <div className="card-body">{children}</div>
            {footer && <footer className="card-foot">{footer}</footer>}
        </section>
    );
}

interface StatProps {
    label: string;
    value: ReactNode;
    hint?: ReactNode;
}

/** A single figure with its label, used in rows that reflow by themselves. */
export function Stat({ label, value, hint }: StatProps) {
    return (
        <div className="stat">
            <dt>{label}</dt>
            <dd>
                <span className="stat-value numeric">{value}</span>
                {hint && <span className="stat-hint muted small">{hint}</span>}
            </dd>
        </div>
    );
}

export function StatRow({ children }: { children: ReactNode }) {
    return <dl className="stat-row">{children}</dl>;
}
