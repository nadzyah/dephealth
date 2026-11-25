/**
 * What the service is, for a reader who has not submitted anything yet.
 */

import { Link } from "react-router-dom";

import { SectionNav } from "../components/layout/SectionNav";
import { Card } from "../components/ui/Card";
import { ExternalLink } from "../components/ui/ExternalLink";

export default function AboutPage() {
    return (
        <div className="stack">
            <section>
                <h1>About</h1>
                <p>
                    dephealth assesses the Cargo dependencies a project already has. It resolves a
                    submitted <code>Cargo.lock</code> to the full tree it stands for, ranks that
                    tree by the risk that maintenance of each package ceases, and forecasts how
                    adoption of the package is likely to move.
                </p>
            </section>

            <SectionNav />

            <Card title="Data Sources">
                <p>
                    Scores are derived from consumption data published by crates.io joined with the
                    public development activity of the repository behind a package. Nothing is
                    computed during a request. The models run on a schedule and a report reads their
                    stored output, so every figure carries the date of the data behind it.
                </p>
                <p>
                    <Link to="/method">Method</Link> sets out what counts as abandonment, how
                    contributor activity is aggregated, and how old each source currently is.
                </p>
            </Card>

            <Card title="Data Handling">
                <p>
                    A lockfile is read, assessed and discarded. Nothing is stored but the result,
                    and there is no account to create. The link returned with a report is the only
                    way back to it, and the links this browser has seen are kept in the browser
                    itself.
                </p>
                <p>
                    A lockfile records the packages a project resolved to rather than its own
                    source, so no source code is transmitted in order to obtain an assessment.
                </p>
            </Card>

            <Card title="Interface">
                <p>
                    The client is built from one set of colour, type and spacing tokens and a small
                    set of components, which the <Link to="/design-system">design system</Link>{" "}
                    lists in every state they occupy. Contrast ratios there are measured from the
                    tokens in force rather than quoted, and the page follows the theme selected in
                    the header.
                </p>
            </Card>

            <Card title="Project Context">
                <p>
                    dephealth is a diploma project. The service, the client and the data pipeline
                    are developed in the open, and the{" "}
                    <ExternalLink href="https://github.com/nadzyah/dephealth">
                        source repository
                    </ExternalLink>{" "}
                    holds the code along with the written documentation behind it.
                </p>
            </Card>
        </div>
    );
}
