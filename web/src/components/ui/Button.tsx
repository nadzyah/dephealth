import type { ButtonHTMLAttributes, ReactNode } from "react";

import "./Button.css";

export type ButtonVariant = "primary" | "secondary" | "ghost" | "danger";
export type ButtonSize = "medium" | "small";

interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
    variant?: ButtonVariant;
    size?: ButtonSize;
    /** Disables the button and announces that something is in flight. */
    busy?: boolean;
    iconBefore?: ReactNode;
    children: ReactNode;
}

export function Button({
    variant = "secondary",
    size = "medium",
    busy = false,
    iconBefore,
    children,
    className,
    disabled,
    type = "button",
    ...rest
}: ButtonProps) {
    return (
        <button
            type={type}
            className={["button", variant, size, className].filter(Boolean).join(" ")}
            disabled={disabled || busy}
            aria-busy={busy || undefined}
            {...rest}
        >
            {busy ? <span className="button-spinner" aria-hidden="true" /> : iconBefore}
            <span>{children}</span>
        </button>
    );
}
