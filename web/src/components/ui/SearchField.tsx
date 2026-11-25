/**
 * The one search input in the application, used by the report tree and by the
 * package list. It lives here rather than beside either of them because a
 * component styled in one route's chunk is unstyled in the other.
 */

import "./SearchField.css";

import { SearchIcon } from "./icons";

interface SearchFieldProps {
    value: string;
    onChange: (value: string) => void;
    /** Describes what is being searched, for a reader who hears the label alone. */
    label: string;
    placeholder?: string;
    className?: string;
}

export function SearchField({
    value,
    onChange,
    label,
    placeholder = "Search by name",
    className,
}: SearchFieldProps) {
    return (
        <div className={["search-field", className].filter(Boolean).join(" ")}>
            <SearchIcon size="1.1em" />
            <input
                type="search"
                value={value}
                onChange={(event) => onChange(event.target.value)}
                placeholder={placeholder}
                aria-label={label}
            />
        </div>
    );
}
