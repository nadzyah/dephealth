/**
 * The assessed tree. Ranked as the report stored it, with search, a filter and
 * sorting over that order.
 *
 * One table serves every width. Above the phone breakpoint it is a table; below
 * it each row becomes a block whose cells carry their own label, which keeps a
 * single accessible structure instead of a second markup for small screens.
 */

import { useMemo, useState } from "react";
import { Link } from "react-router-dom";

import type { ReportEntry } from "../../api/types";
import { RiskBadge } from "../ui/Badge";
import { SearchField } from "../ui/SearchField";

import "./TreeTable.css";

type SortKey = "rank" | "name" | "risk" | "depth";
type Filter = "all" | "scored" | "unresolved" | "direct";

const filters: { value: Filter; label: string }[] = [
    { value: "all", label: "All" },
    { value: "scored", label: "Scored" },
    { value: "unresolved", label: "Unresolved" },
    { value: "direct", label: "Direct Only" },
];

const columns: { key: SortKey; label: string; numeric?: boolean }[] = [
    { key: "rank", label: "Rank", numeric: true },
    { key: "name", label: "Package" },
    { key: "risk", label: "Risk", numeric: true },
    { key: "depth", label: "Depth", numeric: true },
];

/** The column name, shown only where the header row is hidden. */
function CellLabel({ children }: { children: string }) {
    return <span className="cell-label">{children}</span>;
}

interface TreeTableProps {
    entries: ReportEntry[];
    /** Links each scored row to its evidence. */
    token: string;
}

export function TreeTable({ entries, token }: TreeTableProps) {
    const [query, setQuery] = useState("");
    const [filter, setFilter] = useState<Filter>("all");
    const [sort, setSort] = useState<SortKey>("rank");
    const [ascending, setAscending] = useState(true);

    const shown = useMemo(() => {
        const needle = query.trim().toLowerCase();

        const kept = entries.filter((entry) => {
            if (needle && !entry.package_name.toLowerCase().includes(needle)) return false;
            if (filter === "scored") return entry.resolved;
            if (filter === "unresolved") return !entry.resolved;
            if (filter === "direct") return entry.relation === "direct";
            return true;
        });

        const direction = ascending ? 1 : -1;

        return [...kept].sort((left, right) => {
            switch (sort) {
                case "name":
                    return direction * left.package_name.localeCompare(right.package_name);
                case "risk": {
                    // An entry with no score sorts last whichever way the column
                    // is pointing, since it has no place on the scale
                    const a = left.risk?.probability;
                    const b = right.risk?.probability;
                    if (a === undefined && b === undefined) return 0;
                    if (a === undefined) return 1;
                    if (b === undefined) return -1;
                    return direction * (b - a);
                }
                case "depth":
                    return direction * (left.depth - right.depth || left.ordinal - right.ordinal);
                default:
                    return direction * (left.ordinal - right.ordinal);
            }
        });
    }, [entries, query, filter, sort, ascending]);

    function toggle(key: SortKey) {
        if (key === sort) {
            setAscending(!ascending);
        } else {
            setSort(key);
            setAscending(true);
        }
    }

    return (
        <div className="tree">
            <div className="tree-controls">
                <SearchField
                    value={query}
                    onChange={setQuery}
                    label="Search the tree by package name"
                />

                <div className="tree-filters" role="group" aria-label="Filter the tree">
                    {filters.map(({ value, label }) => (
                        <label key={value} className="tree-filter">
                            <input
                                type="radio"
                                name="tree-filter"
                                value={value}
                                checked={filter === value}
                                onChange={() => setFilter(value)}
                            />
                            <span>{label}</span>
                        </label>
                    ))}
                </div>
            </div>

            {/* role="status" carries an implicit polite live region, so the
                count is announced when a filter changes it */}
            <p className="muted small" role="status">
                {shown.length === entries.length
                    ? `${entries.length} entries`
                    : `${shown.length} of ${entries.length} entries`}
            </p>

            <div className="tree-scroll">
                <table className="tree-table" role="table">
                    <caption className="visually-hidden">
                        The assessed dependency tree, ranked by the risk that maintenance ceases
                    </caption>
                    <thead role="rowgroup">
                        <tr role="row">
                            {columns.map((column) => (
                                <th
                                    key={column.key}
                                    scope="col"
                                    role="columnheader"
                                    className={column.numeric ? "numeric-column" : undefined}
                                    aria-sort={
                                        sort === column.key
                                            ? ascending
                                                ? "ascending"
                                                : "descending"
                                            : "none"
                                    }
                                >
                                    <button
                                        type="button"
                                        className="tree-sort"
                                        onClick={() => toggle(column.key)}
                                    >
                                        {column.label}
                                        <span aria-hidden="true" className="tree-sort-mark">
                                            {sort === column.key ? (ascending ? "▲" : "▼") : ""}
                                        </span>
                                    </button>
                                </th>
                            ))}
                            <th scope="col" role="columnheader">
                                Reason
                            </th>
                        </tr>
                    </thead>

                    <tbody role="rowgroup">
                        {shown.map((entry) => (
                            <tr role="row" key={`${entry.package_name}@${entry.package_version}`}>
                                <td role="cell" className="numeric-column numeric">
                                    <CellLabel>Rank</CellLabel>
                                    {entry.ordinal}
                                </td>

                                <td role="cell">
                                    <CellLabel>Package</CellLabel>
                                    {entry.resolved ? (
                                        <Link
                                            to={`/r/${token}/p/${encodeURIComponent(entry.package_name)}`}
                                            className="tree-name touchable"
                                        >
                                            {entry.package_name}
                                        </Link>
                                    ) : (
                                        <span className="tree-name">{entry.package_name}</span>
                                    )}
                                    <span className="muted small"> {entry.package_version}</span>
                                    <span className="tree-relation small muted">
                                        {entry.relation}
                                    </span>
                                </td>

                                <td role="cell" className="numeric-column">
                                    <CellLabel>Risk</CellLabel>
                                    <RiskBadge
                                        probability={entry.risk?.probability ?? null}
                                        horizonDays={entry.risk?.horizon_days}
                                    />
                                </td>

                                <td role="cell" className="numeric-column numeric">
                                    <CellLabel>Depth</CellLabel>
                                    {entry.depth}
                                </td>

                                <td role="cell">
                                    <CellLabel>Reason</CellLabel>
                                    {entry.resolved ? (
                                        <span className="muted small">
                                            {entry.forecast?.insufficient_history
                                                ? "Under twelve months of history, so no forecast"
                                                : entry.forecast?.point_downloads
                                                  ? `Forecast ${Intl.NumberFormat("en", { notation: "compact" }).format(entry.forecast.point_downloads)} downloads at ${entry.forecast.horizon_months} months`
                                                  : "Scored"}
                                        </span>
                                    ) : (
                                        <span className="muted small">
                                            {entry.unresolved?.label}
                                        </span>
                                    )}
                                </td>
                            </tr>
                        ))}
                    </tbody>
                </table>

                {shown.length === 0 && (
                    <p className="tree-none muted">
                        Nothing matches {query ? `“${query}”` : "that filter"}.
                    </p>
                )}
            </div>
        </div>
    );
}
