/**
 * The shapes the API returns, mirroring the schemas in docs/api/openapi.yaml.
 * Field names follow the API rather than the JavaScript convention, so a value
 * can be traced from a screen to a column without a translation table.
 */

export type Relation = "direct" | "indirect";

export type UnresolvedReason =
    | "no_url_declared"
    | "url_unparseable"
    | "host_unsupported"
    | "repository_unreachable"
    | "absent_from_snapshot"
    | "not_a_registry_package"
    | "awaiting_first_score";

export interface Risk {
    probability: number;
    horizon_days: number;
}

export interface Forecast {
    point_downloads: number | null;
    horizon_months: number | null;
    insufficient_history: boolean;
}

export interface Activity {
    distinct_contributors: number | null;
    days_since_last_event: number | null;
    contributor_count_withheld: boolean;
}

export interface Unresolved {
    reason: UnresolvedReason;
    label: string;
    remedy: string;
}

export interface ReportEntry {
    ordinal: number;
    package_name: string;
    package_version: string;
    depth: number;
    relation: Relation;
    resolved: boolean;
    risk?: Risk;
    forecast?: Forecast;
    activity?: Activity;
    unresolved?: Unresolved;
}

export interface ModelRef {
    name: string;
    version: string;
}

export interface Report {
    link?: string;
    assessed_on: string;
    created_at: string;
    data_as_of: { registry: string; events: string };
    method: {
        abandonment_window_days: number;
        risk_model: ModelRef;
        forecast_model: ModelRef;
    };
    counts: { entries: number; resolved: number; unresolved: number };
    withdrawn?: { at: string; reason: string };
    entries: ReportEntry[];
}

export interface Factor {
    code: string;
    label: string;
    description: string;
    observed_value: number;
    contribution: number;
    direction: string;
}

export interface DownloadPoint {
    day: string;
    downloads: number;
}

export interface Resolution {
    is_resolved: boolean;
    label: string;
    remedy: string;
}

export interface Assessment {
    package_name: string;
    latest_version: string | null;
    repository_url: string | null;
    resolution: Resolution;
    risk?: Risk;
    forecast?: Forecast;
    activity: Activity;
    is_abandoned: boolean | null;
    data_as_of: { registry: string | null; events: string | null };
}

export interface EntryDetail {
    entry: ReportEntry;
    factors: Factor[];
    downloads: DownloadPoint[];
    live: Assessment | null;
}

export interface Change {
    package_name: string;
    risk_then: number | null;
    risk_now: number | null;
    change: number | null;
    verdict: string;
}

export interface Changes {
    assessed_on: string;
    previous_assessed_on: string;
    packages: Change[];
}

export interface SourceAge {
    source: string;
    data_as_of: string | null;
    age_days: number | null;
    last_success_at: string | null;
    last_attempt_status: string | null;
    last_attempt_at: string | null;
}

export interface Meta {
    service: string;
    version: string;
    method: {
        abandonment_window_days: number;
        contributor_disclosure_threshold: number;
        abandonment_definition: string;
    };
    sources: SourceAge[];
}

export interface PackageSummary {
    package_name: string;
    latest_version: string | null;
    risk_probability: number | null;
    is_resolved: boolean;
}

export interface PackagePage {
    items: PackageSummary[];
    limit: number;
    offset: number;
}

/** One entry of a manifest a client has already resolved for itself. */
export interface EntryInput {
    name: string;
    version: string;
    depth?: number;
    from_registry?: boolean;
}
