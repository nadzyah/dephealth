/**
 * How old the data behind a score is, shown beside the score rather than on a
 * page about the service. A reader cannot judge a forecast without it.
 */

import "./DataAgeBanner.css";

const day = new Intl.DateTimeFormat("en", { day: "numeric", month: "short", year: "numeric" });

function age(date: string): { label: string; days: number } {
    const then = new Date(`${date}T00:00:00Z`);
    const days = Math.max(0, Math.round((Date.now() - then.getTime()) / (24 * 60 * 60 * 1000)));

    if (days === 0) return { label: "today", days };
    if (days === 1) return { label: "yesterday", days };
    return { label: `${days} days ago`, days };
}

interface DataAgeBannerProps {
    registry: string;
    events: string;
    /** Flags data old enough that a reader should treat the score with care. */
    staleAfterDays?: number;
}

export function DataAgeBanner({ registry, events, staleAfterDays = 3 }: DataAgeBannerProps) {
    const registryAge = age(registry);
    const eventsAge = age(events);
    const stale = Math.max(registryAge.days, eventsAge.days) > staleAfterDays;

    return (
        <aside className={`data-age ${stale ? "stale" : ""}`}>
            <span className="data-age-title">Data behind these figures</span>
            <dl>
                <div>
                    <dt>Registry</dt>
                    <dd>
                        <time dateTime={registry}>{day.format(new Date(registry))}</time>
                        <span className="muted small"> {registryAge.label}</span>
                    </dd>
                </div>
                <div>
                    <dt>Repository events</dt>
                    <dd>
                        <time dateTime={events}>{day.format(new Date(events))}</time>
                        <span className="muted small"> {eventsAge.label}</span>
                    </dd>
                </div>
            </dl>
            {stale && (
                <p className="small">
                    The last ingestion run is older than {staleAfterDays} days, so these figures may
                    have moved.
                </p>
            )}
        </aside>
    );
}
