/**
 * The current assessment of one package, reached from the package list rather
 * than from a report. It shows what the last ingestion run produced, so the
 * figures here move when a run finishes while a stored report keeps its own.
 *
 * The factor decomposition is deliberately absent. It is published as part of a
 * dated report and not on its own, which is why the API addresses it through a
 * report token.
 */

import { Link, useParams } from "react-router-dom";

import { api } from "../api/client";
import { useAsync } from "../hooks/useAsync";
import { DownloadChart } from "../components/charts/DownloadChart";
import { formatProbability } from "../lib/risk";
import { RiskBadge } from "../components/ui/Badge";
import { Card, Stat, StatRow } from "../components/ui/Card";
import { ExternalLink } from "../components/ui/ExternalLink";
import { Empty, Failure, Skeleton } from "../components/ui/States";

const compact = new Intl.NumberFormat("en", { notation: "compact", maximumFractionDigits: 1 });

export default function RegistryPackagePage() {
    const { name = "" } = useParams();
    const assessment = useAsync(() => api.package(name), [name], name.length > 0);
    const series = useAsync(() => api.downloads(name), [name], name.length > 0);

    if (assessment.status === "loading" || assessment.status === "idle") {
        return (
            <div className="stack">
                <Skeleton width="40%" height="2rem" />
                <Skeleton height="12rem" />
                <Skeleton height="8rem" />
            </div>
        );
    }

    if (assessment.status === "failed" && assessment.problem) {
        return (
            <Failure
                problem={assessment.problem}
                onRetry={assessment.problem.isRetryable ? assessment.reload : undefined}
                level={1}
            >
                {!assessment.problem.isRetryable && (
                    <Link to="/packages" className="button secondary touchable">
                        Back to the package list
                    </Link>
                )}
            </Failure>
        );
    }

    const data = assessment.data;
    if (!data) return null;

    const activity = data.activity;

    return (
        <div className="stack">
            <section>
                <p className="small">
                    <Link to="/packages">Packages</Link> / {data.package_name}
                </p>
                <h1>
                    {data.package_name}{" "}
                    {data.latest_version && <span className="muted">{data.latest_version}</span>}
                </h1>
                <div className="row">
                    <RiskBadge
                        probability={data.risk?.probability ?? null}
                        horizonDays={data.risk?.horizon_days}
                    />
                    {data.repository_url && (
                        <ExternalLink href={data.repository_url} className="small">
                            Repository
                        </ExternalLink>
                    )}
                    {data.data_as_of.registry && (
                        <span className="muted small">
                            Registry data as of {data.data_as_of.registry}
                        </span>
                    )}
                </div>
            </section>

            {data.risk ? (
                <Card title="Current Score">
                    <StatRow>
                        <Stat
                            label="Risk that maintenance ceases"
                            value={formatProbability(data.risk.probability)}
                            hint={`within ${data.risk.horizon_days} days`}
                        />
                        <Stat
                            label="Adoption forecast"
                            value={
                                data.forecast?.point_downloads
                                    ? compact.format(data.forecast.point_downloads)
                                    : "none"
                            }
                            hint={
                                data.forecast?.insufficient_history
                                    ? "under twelve months of history"
                                    : `downloads at ${data.forecast?.horizon_months} months`
                            }
                        />
                        {data.is_abandoned !== null && (
                            <Stat
                                label="Abandoned by the definition"
                                value={data.is_abandoned ? "yes" : "no"}
                                hint={<Link to="/method">Definition</Link>}
                            />
                        )}
                    </StatRow>
                </Card>
            ) : (
                <Card title="Unscored Package">
                    <Empty title="No Current Score">
                        <p className="muted">{data.resolution.label}</p>
                        <p className="muted small">{data.resolution.remedy}</p>
                    </Empty>
                </Card>
            )}

            <Card
                title="Downloads"
                action={<span className="muted small">as recorded by the registry</span>}
            >
                {series.status === "ready" && series.data ? (
                    <DownloadChart
                        points={series.data}
                        label={`Daily downloads of ${data.package_name}`}
                    />
                ) : (
                    <Skeleton height="10rem" />
                )}
            </Card>

            <Card title="Contributor Activity">
                {activity ? (
                    <StatRow>
                        <Stat
                            label="Distinct contributors"
                            value={
                                activity.contributor_count_withheld
                                    ? "withheld"
                                    : (activity.distinct_contributors ?? "unknown")
                            }
                            hint={
                                activity.contributor_count_withheld ? (
                                    <Link to="/method">Disclosure threshold</Link>
                                ) : (
                                    "on the declared repository"
                                )
                            }
                        />
                        <Stat
                            label="Days since the last event"
                            value={activity.days_since_last_event ?? "none observed"}
                        />
                    </StatRow>
                ) : (
                    <p className="muted small">
                        No activity was stored for this package. Packages without a score have none.
                    </p>
                )}
            </Card>

            <p className="small muted">
                A report records the figures that held when it was generated. The figures on this
                screen are the current ones.
            </p>
        </div>
    );
}
