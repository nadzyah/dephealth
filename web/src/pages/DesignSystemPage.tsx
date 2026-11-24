/**
 * The component library, on a page, in the application it belongs to.
 *
 * It exists for two reasons. A reviewer of the interface can see every piece and
 * every state in one place, including the ones that are hard to reach by using
 * the application, such as a failure. And the contrast figures are computed from
 * the live tokens here rather than quoted, so the page cannot claim a ratio the
 * stylesheet does not have.
 */

import { useEffect, useState } from "react";

import { contrastRatio, tokenValue } from "../lib/contrast";
import type { Factor } from "../api/types";
import { DownloadChart } from "../components/charts/DownloadChart";
import { FactorBars } from "../components/charts/FactorBars";
import { Badge, RiskBadge } from "../components/ui/Badge";
import { Button } from "../components/ui/Button";
import { Card, Stat, StatRow } from "../components/ui/Card";
import { Empty, Failure, Loading, TableSkeleton } from "../components/ui/States";
import { ApiProblem } from "../api/problem";
import { UploadIcon } from "../components/ui/icons";

import "./DesignSystemPage.css";

const textTokens = [
    "--color-text",
    "--color-text-muted",
    "--color-accent",
    "--color-risk-high",
    "--color-risk-medium",
    "--color-risk-low",
];

const markTokens = ["--chart-series", "--chart-positive", "--chart-negative"];

const typeScale = [
    ["--text-3xl", "Display"],
    ["--text-2xl", "Page title"],
    ["--text-xl", "Section"],
    ["--text-lg", "Card title"],
    ["--text-base", "Body"],
    ["--text-sm", "Secondary"],
    ["--text-xs", "Label"],
];

const spacing = ["--space-1", "--space-2", "--space-3", "--space-4", "--space-5", "--space-6"];

const exampleFactors: Factor[] = [
    {
        code: "days_since_last_event",
        label: "Days since the last development event",
        description: "How long the repository has been quiet",
        observed_value: 1920,
        contribution: 2.41,
        direction: "raised the risk",
    },
    {
        code: "contributor_count",
        label: "Active contributors",
        description: "Distinct contributors in the window",
        observed_value: 0,
        contribution: 1.18,
        direction: "raised the risk",
    },
    {
        code: "download_trend",
        label: "Change in downloads",
        description: "Direction of the consumption series",
        observed_value: -0.214,
        contribution: -0.36,
        direction: "lowered the risk",
    },
];

const exampleSeries = Array.from({ length: 60 }, (_, index) => {
    const date = new Date(Date.UTC(2026, 8, 1));
    date.setUTCDate(date.getUTCDate() + index);
    return {
        day: date.toISOString().slice(0, 10),
        downloads: Math.round(1_200_000 + Math.sin(index / 6) * 180_000 + index * 4_200),
    };
});

const exampleProblem = new ApiProblem({
    type: "/problems/report-not-found",
    title: "No such report",
    status: 404,
    detail: "The link has never addressed a report on this deployment.",
});

/** Reads the tokens after paint, so the figures follow the chosen theme. */
function useContrastTable(tokens: string[], against: string) {
    const [rows, setRows] = useState<{ token: string; value: string; ratio: number }[]>([]);

    useEffect(() => {
        const surface = tokenValue(against);
        setRows(
            tokens.map((token) => {
                const value = tokenValue(token);
                return {
                    token,
                    value,
                    ratio: value && surface ? contrastRatio(value, surface) : 0,
                };
            }),
        );
    }, [tokens, against]);

    return rows;
}

export default function DesignSystemPage() {
    const textRows = useContrastTable(textTokens, "--color-surface");
    const markRows = useContrastTable(markTokens, "--color-surface");

    return (
        <div className="stack">
            <section>
                <h1>Design system</h1>
                <p>
                    One palette, one type scale, one spacing scale and one set of components, used
                    at every width. The figures below are computed from the tokens in force as you
                    read them, so switching the theme in the header changes them.
                </p>
            </section>

            <Card title="Colour, and what it is checked against">
                <h3>Text, which WCAG 2.1 AA holds to 4.5:1</h3>
                <ul className="swatches">
                    {textRows.map((row) => (
                        <li key={row.token}>
                            <span className="swatch" style={{ background: row.value }} />
                            <code className="small">{row.token}</code>
                            <span className="small numeric">{row.value}</span>
                            <span className="small numeric">
                                {row.ratio.toFixed(2)}:1{" "}
                                {row.ratio >= 4.5 ? (
                                    <Badge tone="low">passes</Badge>
                                ) : (
                                    <Badge tone="high">fails</Badge>
                                )}
                            </span>
                        </li>
                    ))}
                </ul>

                <h3>Chart marks, which 1.4.11 holds to 3:1</h3>
                <p className="muted small">
                    A separate pair from the risk text colours. Red against green fails for a reader
                    with deuteranopia, so the diverging pair is red against blue, which the palette
                    validator puts at delta E 18 rather than 6.6.
                </p>
                <ul className="swatches">
                    {markRows.map((row) => (
                        <li key={row.token}>
                            <span className="swatch" style={{ background: row.value }} />
                            <code className="small">{row.token}</code>
                            <span className="small numeric">{row.value}</span>
                            <span className="small numeric">
                                {row.ratio.toFixed(2)}:1{" "}
                                {row.ratio >= 3 ? (
                                    <Badge tone="low">passes</Badge>
                                ) : (
                                    <Badge tone="high">fails</Badge>
                                )}
                            </span>
                        </li>
                    ))}
                </ul>
            </Card>

            <div className="grid two">
                <Card title="Type scale">
                    <ul className="type-scale">
                        {typeScale.map(([token, label]) => (
                            <li key={token} style={{ fontSize: `var(${token})` }}>
                                {label}
                                <code className="small muted"> {token}</code>
                            </li>
                        ))}
                    </ul>
                </Card>

                <Card title="Spacing">
                    <ul className="spacing">
                        {spacing.map((token) => (
                            <li key={token}>
                                <span className="spacing-bar" style={{ width: `var(${token})` }} />
                                <code className="small">{token}</code>
                            </li>
                        ))}
                    </ul>
                </Card>
            </div>

            <Card title="Buttons, in every state">
                <table className="states-table">
                    <thead>
                        <tr>
                            <th scope="col">Variant</th>
                            <th scope="col">Default</th>
                            <th scope="col">Busy</th>
                            <th scope="col">Disabled</th>
                            <th scope="col">With an icon</th>
                        </tr>
                    </thead>
                    <tbody>
                        {(["primary", "secondary", "ghost", "danger"] as const).map((variant) => (
                            <tr key={variant}>
                                <td data-label="Variant">
                                    <code className="small">{variant}</code>
                                </td>
                                <td data-label="Default">
                                    <Button variant={variant}>Assess</Button>
                                </td>
                                <td data-label="Busy">
                                    <Button variant={variant} busy>
                                        Assessing
                                    </Button>
                                </td>
                                <td data-label="Disabled">
                                    <Button variant={variant} disabled>
                                        Assess
                                    </Button>
                                </td>
                                <td data-label="With an icon">
                                    <Button
                                        variant={variant}
                                        iconBefore={<UploadIcon size="1em" />}
                                    >
                                        Upload
                                    </Button>
                                </td>
                            </tr>
                        ))}
                    </tbody>
                </table>
                <p className="muted small">
                    Hover and focus are not shown here because they are states of the pointer and
                    the keyboard. Every control takes a two pixel focus ring on{" "}
                    <code>:focus-visible</code>, and is at least 44 pixels on a touch screen.
                </p>
            </Card>

            <div className="grid two">
                <Card title="Risk bands">
                    <div className="row">
                        <RiskBadge probability={0.971} horizonDays={365} />
                        <RiskBadge probability={0.412} horizonDays={365} />
                        <RiskBadge probability={0.031} horizonDays={365} />
                        <RiskBadge probability={null} />
                    </div>
                    <p className="muted small">
                        Where the bands fall is a presentation choice, so the figure is always
                        beside the word and the word is never the only thing carrying it.
                    </p>
                </Card>

                <Card title="Badges">
                    <div className="row">
                        <Badge>neutral</Badge>
                        <Badge tone="accent">accent</Badge>
                        <Badge tone="high">high</Badge>
                        <Badge tone="medium">medium</Badge>
                        <Badge tone="low">low</Badge>
                    </div>
                </Card>
            </div>

            <Card title="Figures">
                <StatRow>
                    <Stat label="Entries" value={39} />
                    <Stat label="Scored" value={4} />
                    <Stat label="Unresolved" value={35} hint="each with a reason" />
                </StatRow>
            </Card>

            <div className="grid two">
                <Card title="Loading">
                    <Loading label="Assessing the manifest" />
                </Card>
                <Card title="Skeleton">
                    <TableSkeleton label="Loading rows" rows={3} />
                </Card>
                <Card title="Empty">
                    <Empty title="Nothing matches">
                        <p className="muted">No package in the snapshot has that name.</p>
                    </Empty>
                </Card>
                <Card title="Failure">
                    <Failure problem={exampleProblem} />
                </Card>
            </div>

            <Card title="Charts">
                <h3>A measure over time</h3>
                <DownloadChart points={exampleSeries} label="Daily downloads, example series" />
                <h3 style={{ marginTop: "var(--space-5)" }}>Polarity</h3>
                <FactorBars factors={exampleFactors} />
            </Card>

            <Card title="Breakpoints">
                <ul className="breakpoints">
                    <li>
                        <strong>under 48rem</strong> phone. One column, navigation at the bottom
                        under the thumb, the table reflows to labelled blocks.
                    </li>
                    <li>
                        <strong>48rem</strong> tablet. Two columns, navigation returns to the
                        header, the table becomes a table.
                    </li>
                    <li>
                        <strong>64rem</strong> desktop. Three columns where the content suits it, a
                        wider measure.
                    </li>
                    <li>
                        <strong>75rem and beyond</strong> the content stops growing and centres, so
                        a 4K or ultrawide window does not stretch a line of text across it.
                    </li>
                </ul>
            </Card>
        </div>
    );
}
