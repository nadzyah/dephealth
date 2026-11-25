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
import { SectionNav } from "../components/layout/SectionNav";
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

const markTokens = ["--chart-series", "--chart-raised", "--chart-lowered"];

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
    detail: "No report exists for this link.",
});

/** Reads the tokens after paint, so the figures follow the chosen theme. */
function useContrastTable(tokens: string[], against: string) {
    const [rows, setRows] = useState<{ token: string; value: string; ratio: number }[]>([]);

    useEffect(() => {
        // After the next paint, so the figures describe the theme now applied
        // to the document rather than the one being replaced
        const frame = requestAnimationFrame(() => {
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
        });

        return () => cancelAnimationFrame(frame);
    }, [tokens, against]);

    return rows;
}

export default function DesignSystemPage() {
    const textRows = useContrastTable(textTokens, "--color-surface");
    const markRows = useContrastTable(markTokens, "--color-surface");

    return (
        <div className="stack">
            <section>
                <h1>Design System</h1>
                <p>
                    The tokens and components the client is built from, in every state they occupy.
                    Contrast ratios are computed from the tokens currently in force and follow the
                    theme selected in the header.
                </p>
            </section>

            <SectionNav />

            <Card title="Colour">
                <h3>Text Contrast</h3>
                <p className="muted small">
                    Every pair below is held to the 4.5:1 that WCAG 2.1 AA requires of body text,
                    and the ratio is computed from the tokens in force.
                </p>
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

                <h3>Non-Text Contrast</h3>
                <p className="muted small">
                    Control edges and chart marks are held to the 3:1 of WCAG 1.4.11 rather than to
                    the ratio required of text. The three marks also have to be told apart from one
                    another, since a download series and the two directions of a factor bar can
                    share a screen. Red against green is lost to deuteranopia, so a factor bar is
                    red against purple, and no two marks come closer than delta E 15.6 under a
                    colour vision simulation, where the floor is 8.
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
                <Card title="Type Scale">
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

            <Card title="Buttons">
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
                        {(["primary", "secondary", "danger"] as const).map((variant) => (
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
                <Card title="Risk Bands">
                    <div className="row">
                        <RiskBadge probability={0.971} horizonDays={365} />
                        <RiskBadge probability={0.412} horizonDays={365} />
                        <RiskBadge probability={0.031} horizonDays={365} />
                        <RiskBadge probability={null} />
                    </div>
                    <p className="muted small">
                        Where the bands fall is a presentation choice. The figure always appears
                        beside the word, and the word never carries the meaning alone.
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
                    <Empty title="No Matches">
                        <p className="muted">No package in the snapshot has that name.</p>
                    </Empty>
                </Card>
                <Card title="Failure">
                    <Failure problem={exampleProblem} />
                </Card>
            </div>

            <Card title="Charts">
                <h3>Time Series</h3>
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
