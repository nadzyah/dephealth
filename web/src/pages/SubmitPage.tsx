/**
 * Submitting a manifest, and reopening a report from its link. The entry point
 * for the assessment of a tree before adoption.
 */

import { useState } from "react";
import { Link, useNavigate } from "react-router-dom";

import { DEMO, api } from "../api/client";
import { useSubmit } from "../hooks/useAsync";
import { projectName, tokenFromLink } from "../lib/manifest";
import { useAppStore, selectRecent } from "../store/useAppStore";
import { FileDrop } from "../components/FileDrop";
import { Card } from "../components/ui/Card";
import { Button } from "../components/ui/Button";

import "./SubmitPage.css";

export default function SubmitPage() {
    const navigate = useNavigate();
    const remember = useAppStore((state) => state.remember);
    const notify = useAppStore((state) => state.notify);
    const recent = useAppStore(selectRecent);

    const submission = useSubmit(api.submitLockfile);
    const [link, setLink] = useState("");
    const [linkError, setLinkError] = useState<string | undefined>(undefined);

    async function onFile(_file: File, text: string) {
        const report = await submission.submit(text);
        if (!report?.link) return;

        const token = tokenFromLink(report.link);
        if (!token) return;

        remember({
            token,
            assessedOn: report.assessed_on,
            entries: report.counts.entries,
            project: projectName(text),
        });

        notify({
            kind: "success",
            title: "Assessment stored",
            detail: `${report.counts.resolved} of ${report.counts.entries} entries scored.`,
        });

        navigate(`/r/${token}`);
    }

    function onOpenLink(event: React.FormEvent) {
        event.preventDefault();

        const token = tokenFromLink(link);
        if (!token) {
            setLinkError("That is not a report link. A token is 64 hexadecimal characters.");
            return;
        }

        setLinkError(undefined);
        navigate(`/r/${token}`);
    }

    return (
        <div className="stack">
            <section>
                <h1>Dependency Assessment</h1>
                <p>
                    A submitted <code>Cargo.lock</code> is resolved to its transitive tree and
                    ranked by the risk that maintenance ceases, with an adoption forecast and the
                    evidence behind each score. No account is required, and the file is discarded
                    once it has been read.
                </p>
            </section>

            {DEMO && (
                <aside className="data-age">
                    <span className="data-age-title">Demo</span>
                    <p className="small" style={{ margin: 0 }}>
                        This deployment answers from responses captured from the running service, so
                        it can be used without a database behind it. Submitting any lockfile opens
                        the same stored report.
                    </p>
                </aside>
            )}

            <FileDrop
                onFile={(file, text) => void onFile(file, text)}
                busy={submission.status === "loading"}
                error={submission.problem?.detail}
            />

            {submission.problem?.field<number>("line") !== undefined && (
                <p className="small muted">
                    Reading stopped at line {submission.problem.field<number>("line")}, so nothing
                    was assessed.
                </p>
            )}

            <div className="grid two">
                <Card title="Report Link">
                    <form onSubmit={onOpenLink} className="stack tight">
                        <label htmlFor="report-link" className="small muted">
                            Paste the permanent link, or the token from it
                        </label>
                        <input
                            id="report-link"
                            name="report-link"
                            type="text"
                            autoComplete="off"
                            spellCheck={false}
                            value={link}
                            aria-invalid={linkError ? true : undefined}
                            aria-describedby={linkError ? "report-link-error" : undefined}
                            onChange={(event) => setLink(event.target.value)}
                            placeholder={DEMO ? "demo" : "https://…/r/9f2c1ab4…"}
                        />
                        {linkError && (
                            <p id="report-link-error" className="file-drop-error" role="alert">
                                {linkError}
                            </p>
                        )}
                        <div>
                            <Button type="submit" variant="secondary">
                                Open
                            </Button>
                        </div>
                    </form>
                </Card>

                <Card title="Recent Reports">
                    {recent.length === 0 ? (
                        <p className="muted small">
                            Nothing yet. Reports you open appear here, and stay in this browser.
                        </p>
                    ) : (
                        <ul className="recent">
                            {recent.map((report) => (
                                <li key={report.token}>
                                    <Link to={`/r/${report.token}`} className="touchable">
                                        {report.project ?? "Lockfile"}
                                    </Link>{" "}
                                    <span className="muted small">
                                        {report.assessedOn}, {report.entries} entries
                                    </span>
                                </li>
                            ))}
                        </ul>
                    )}
                </Card>
            </div>
        </div>
    );
}
