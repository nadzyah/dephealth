/**
 * What a score means, read from the service rather than written here, so the
 * page cannot disagree with the figures it explains.
 */

import { api } from "../api/client";
import { useAsync } from "../hooks/useAsync";
import { Card, Stat, StatRow } from "../components/ui/Card";
import { Failure, Skeleton } from "../components/ui/States";

const dateTime = new Intl.DateTimeFormat("en", { dateStyle: "medium", timeStyle: "short" });

const sourceNames: Record<string, string> = {
    crates_io_dump: "crates.io database dump",
    gh_archive: "GH Archive event files",
};

export default function MethodPage() {
    const meta = useAsync(() => api.meta(), []);

    return (
        <div className="stack">
            <section>
                <h1>Method</h1>
                <p>
                    A score here is a statement about a package and the repository behind it, from
                    consumption data joined with the public activity of contributors. Nothing is
                    computed while you wait: the models run on a schedule and the application reads
                    what they stored, which is why every figure arrives with a date.
                </p>
            </section>

            {meta.status === "loading" && <Skeleton height="10rem" />}

            {meta.status === "failed" && meta.problem && (
                <Failure problem={meta.problem} onRetry={meta.reload} level={2} />
            )}

            {meta.status === "ready" && meta.data && (
                <>
                    <Card title="The modelled event">
                        <p>{meta.data.method.abandonment_definition}</p>
                        <StatRow>
                            <Stat
                                label="Abandonment window"
                                value={`${meta.data.method.abandonment_window_days} days`}
                                hint="with no development event from anyone"
                            />
                            <Stat
                                label="Disclosure threshold"
                                value={meta.data.method.contributor_disclosure_threshold}
                                hint="contributors, below which a count is withheld"
                            />
                        </StatRow>
                    </Card>

                    <Card title="Two consequences worth knowing">
                        <p>
                            A package that is finished rather than abandoned scores as being at risk
                            under this definition, which in the Rust ecosystem is a real category of
                            small, stable crates. That is why every detail view shows the activity
                            the score was computed from and not only the score.
                        </p>
                        <p>
                            A package maintained somewhere other than its declared repository
                            appears inactive. Resolution can only partly mitigate that, and an entry
                            it cannot resolve is reported with a reason rather than guessed at.
                        </p>
                    </Card>

                    <Card title="Contributor data">
                        <p>
                            Public development events are personal data. Activity is aggregated to
                            the package before it is stored, the raw event files are discarded, and
                            there is no per-contributor view anywhere in the system. A count below
                            the threshold above is withheld rather than rounded, while a count of
                            zero is published, because it describes nobody.
                        </p>
                    </Card>

                    <Card title="How old the data is">
                        <ul className="stack tight" style={{ listStyle: "none", padding: 0 }}>
                            {meta.data.sources.map((source) => (
                                <li key={source.source}>
                                    <strong>{sourceNames[source.source] ?? source.source}</strong>
                                    <div className="muted small">
                                        {source.data_as_of
                                            ? `covers up to ${source.data_as_of}, ${source.age_days} days old`
                                            : "never ingested"}
                                        {source.last_success_at &&
                                            `, last run ${dateTime.format(new Date(source.last_success_at))}`}
                                    </div>
                                </li>
                            ))}
                        </ul>
                    </Card>

                    <p className="muted small">
                        {meta.data.service} {meta.data.version}
                    </p>
                </>
            )}
        </div>
    );
}
