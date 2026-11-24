/**
 * The observed download series. One measure over time, so a line, on one axis,
 * with a crosshair and a tooltip on hover and on keyboard focus.
 *
 * Drawn as SVG with a viewBox and no width, so it fills its container at any
 * screen size and stays sharp at any pixel density. One series needs no legend,
 * since the heading names it, and the last value is labelled directly rather
 * than every point being numbered.
 */

import { useId, useMemo, useState } from "react";

import type { DownloadPoint } from "../../api/types";

import "./DownloadChart.css";

/** The drawing happens in these coordinates and the viewBox scales them. */
const WIDTH = 720;
const HEIGHT = 240;
const PAD = { top: 16, right: 16, bottom: 28, left: 56 };

const compact = new Intl.NumberFormat("en", { notation: "compact", maximumFractionDigits: 1 });
const full = new Intl.NumberFormat("en");
const day = new Intl.DateTimeFormat("en", { day: "numeric", month: "short", year: "numeric" });
const shortDay = new Intl.DateTimeFormat("en", { day: "numeric", month: "short" });

interface DownloadChartProps {
    points: DownloadPoint[];
    /** Names the series, since there is no legend. */
    label: string;
}

export function DownloadChart({ points, label }: DownloadChartProps) {
    const titleId = useId();
    const [active, setActive] = useState<number | undefined>(undefined);

    const plot = useMemo(() => {
        if (points.length === 0) return undefined;

        const highest = Math.max(...points.map((point) => point.downloads));
        const ceiling = highest === 0 ? 1 : highest;

        const innerWidth = WIDTH - PAD.left - PAD.right;
        const innerHeight = HEIGHT - PAD.top - PAD.bottom;

        const x = (index: number) =>
            PAD.left +
            (points.length === 1 ? innerWidth / 2 : (index / (points.length - 1)) * innerWidth);
        const y = (value: number) => PAD.top + innerHeight - (value / ceiling) * innerHeight;

        const line = points.map((point, index) => `${x(index)},${y(point.downloads)}`).join(" ");
        const area = `${PAD.left},${PAD.top + innerHeight} ${line} ${x(points.length - 1)},${PAD.top + innerHeight}`;

        // Four lines is enough to read a level by, and the grid stays recessive
        const ticks = [0, 0.25, 0.5, 0.75, 1].map((share) => ({
            value: ceiling * share,
            y: y(ceiling * share),
        }));

        return { x, y, line, area, ticks, ceiling, innerHeight };
    }, [points]);

    if (!plot) {
        return <p className="muted small">No download series was recorded for this package.</p>;
    }

    const last = points[points.length - 1];
    const shown = active ?? points.length - 1;
    const shownPoint = points[shown];

    function clamp(index: number) {
        return Math.min(points.length - 1, Math.max(0, index));
    }

    /** Pointer position to the nearest day, through the viewBox coordinates. */
    function onMove(event: React.PointerEvent<SVGSVGElement>) {
        const box = event.currentTarget.getBoundingClientRect();
        const inView = ((event.clientX - box.left) / box.width) * WIDTH;
        const share = (inView - PAD.left) / (WIDTH - PAD.left - PAD.right);
        setActive(clamp(Math.round(share * (points.length - 1))));
    }

    function onKeyDown(event: React.KeyboardEvent<SVGSVGElement>) {
        const step = event.key === "ArrowLeft" ? -1 : event.key === "ArrowRight" ? 1 : 0;
        if (step === 0) return;
        event.preventDefault();
        setActive((current) => clamp((current ?? points.length - 1) + step));
    }

    return (
        <figure className="download-chart">
            <svg
                viewBox={`0 0 ${WIDTH} ${HEIGHT}`}
                role="img"
                aria-labelledby={titleId}
                tabIndex={0}
                onPointerMove={onMove}
                onPointerLeave={() => setActive(undefined)}
                onKeyDown={onKeyDown}
            >
                <title id={titleId}>
                    {`${label}. ${points.length} days, from ${day.format(new Date(points[0].day))} to ${day.format(new Date(last.day))}, ending at ${full.format(last.downloads)} downloads.`}
                </title>

                {plot.ticks.map((tick) => (
                    <g key={tick.value}>
                        <line
                            className="chart-grid-line"
                            x1={PAD.left}
                            x2={WIDTH - PAD.right}
                            y1={tick.y}
                            y2={tick.y}
                        />
                        <text
                            className="chart-tick"
                            x={PAD.left - 8}
                            y={tick.y + 4}
                            textAnchor="end"
                        >
                            {compact.format(tick.value)}
                        </text>
                    </g>
                ))}

                <polygon className="chart-area" points={plot.area} />
                <polyline className="chart-line" points={plot.line} />

                <text className="chart-tick" x={PAD.left} y={HEIGHT - 8}>
                    {shortDay.format(new Date(points[0].day))}
                </text>
                <text className="chart-tick" x={WIDTH - PAD.right} y={HEIGHT - 8} textAnchor="end">
                    {shortDay.format(new Date(last.day))}
                </text>

                <line
                    className="chart-crosshair"
                    x1={plot.x(shown)}
                    x2={plot.x(shown)}
                    y1={PAD.top}
                    y2={PAD.top + plot.innerHeight}
                />
                <circle
                    className="chart-point"
                    cx={plot.x(shown)}
                    cy={plot.y(shownPoint.downloads)}
                    r="5"
                />
            </svg>

            <figcaption>
                <span className="chart-readout">
                    <strong className="numeric">{full.format(shownPoint.downloads)}</strong>
                    <span className="muted small">
                        {" downloads on "}
                        {day.format(new Date(shownPoint.day))}
                    </span>
                </span>
                <span className="muted small">
                    {active === undefined
                        ? "Hover, or focus the chart and use the arrow keys"
                        : `${points.length} days observed`}
                </span>
            </figcaption>
        </figure>
    );
}
