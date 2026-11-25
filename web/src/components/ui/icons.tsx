/**
 * Icons as inline SVG, so they stay sharp at any pixel density, take their
 * colour from the text around them, and scale with the font size instead of
 * needing a second asset for a dense screen.
 */

interface IconProps {
    /** Relative to the current font size. */
    size?: string;
    className?: string;
}

function Svg({
    size = "1.25em",
    className,
    children,
    viewBox = "0 0 24 24",
}: IconProps & { children: React.ReactNode; viewBox?: string }) {
    return (
        <svg
            width={size}
            height={size}
            viewBox={viewBox}
            fill="none"
            stroke="currentColor"
            strokeWidth="1.75"
            strokeLinecap="round"
            strokeLinejoin="round"
            aria-hidden="true"
            focusable="false"
            className={className}
        >
            {children}
        </svg>
    );
}

export const UploadIcon = (props: IconProps) => (
    <Svg {...props}>
        <path d="M12 16V4" />
        <path d="m7 9 5-5 5 5" />
        <path d="M4 16v2a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-2" />
    </Svg>
);

export const TreeIcon = (props: IconProps) => (
    <Svg {...props}>
        <circle cx="6" cy="6" r="2" />
        <circle cx="18" cy="12" r="2" />
        <circle cx="18" cy="19" r="2" />
        <path d="M8 6h4a2 2 0 0 1 2 2v2a2 2 0 0 0 2 2" />
        <path d="M14 10v7a2 2 0 0 0 2 2" />
    </Svg>
);

export const BookIcon = (props: IconProps) => (
    <Svg {...props}>
        <path d="M4 5a2 2 0 0 1 2-2h12v18H6a2 2 0 0 1-2-2z" />
        <path d="M8 7h7M8 11h7" />
    </Svg>
);

export const SettingsIcon = (props: IconProps) => (
    <Svg {...props}>
        <circle cx="12" cy="12" r="3" />
        <path d="M12 2v3M12 19v3M4.2 4.2l2.1 2.1M17.7 17.7l2.1 2.1M2 12h3M19 12h3M4.2 19.8l2.1-2.1M17.7 6.3l2.1-2.1" />
    </Svg>
);

export const CopyIcon = (props: IconProps) => (
    <Svg {...props}>
        <rect x="9" y="9" width="11" height="11" rx="2" />
        <path d="M5 15V6a2 2 0 0 1 2-2h8" />
    </Svg>
);

export const CheckIcon = (props: IconProps) => (
    <Svg {...props}>
        <path d="m4 12.5 5 5L20 6.5" />
    </Svg>
);

export const WarningIcon = (props: IconProps) => (
    <Svg {...props}>
        <path d="M12 4 2.5 20h19z" />
        <path d="M12 10v4M12 17.2v.1" />
    </Svg>
);

export const CloseIcon = (props: IconProps) => (
    <Svg {...props}>
        <path d="M5 5l14 14M19 5 5 19" />
    </Svg>
);

export const ChevronRightIcon = (props: IconProps) => (
    <Svg {...props}>
        <path d="m9 5 7 7-7 7" />
    </Svg>
);

export const ChevronDownIcon = (props: IconProps) => (
    <Svg {...props}>
        <path d="m5 9 7 7 7-7" />
    </Svg>
);

/** The direction a column is sorted in. Decorative: the header carries
 *  aria-sort, which is what a screen reader announces. */
export const SortAscendingIcon = (props: IconProps) => (
    <Svg {...props}>
        <path d="m7 14 5-5 5 5" />
    </Svg>
);

export const SortDescendingIcon = (props: IconProps) => (
    <Svg {...props}>
        <path d="m7 10 5 5 5-5" />
    </Svg>
);

export const SearchIcon = (props: IconProps) => (
    <Svg {...props}>
        <circle cx="11" cy="11" r="6" />
        <path d="m16 16 4 4" />
    </Svg>
);
