/**
 * Submitting a manifest, and reopening a report from its link. The entry point
 * for the assessment of a tree before adoption.
 */

import { useState } from "react";
import { useNavigate } from "react-router-dom";

import { DEMO, api } from "../api/client";
import { useSubmit } from "../hooks/useAsync";
import { tokenFromLink } from "../lib/manifest";
import { useAppStore, selectRecent } from "../store/useAppStore";
import { FileDrop } from "../components/FileDrop";
import { Card } from "../components/ui/Card";
import { Button } from "../components/ui/Button";

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
                <h1>Assess a dependency tree</h1>
                <p>
                    Submit a <code>Cargo.lock</code> and get the tree ranked by the risk that
                    maintenance ceases, with an adoption forecast and the evidence behind every
                    score. No account, and the file is discarded once it has been read.
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
                    The service stopped reading at line {submission.problem.field<number>("line")}.
                    Nothing was assessed, because a partial tree would understate the exposure.
                </p>
            )}

            <div className="grid two">
                <Card title="Open a stored report">
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

                <Card title="Opened from this browser">
                    {recent.length === 0 ? (
                        <p className="muted small">
                            Nothing yet. A report you open is remembered here, in this browser only.
                        </p>
                    ) : (
                        <ul className="stack tight" style={{ listStyle: "none", padding: 0 }}>
                            {recent.map((report) => (
                                <li key={report.token}>
                                    <Button
                                        variant="ghost"
                                        size="small"
                                        onClick={() => navigate(`/r/${report.token}`)}
                                    >
                                        {`${report.assessedOn}, ${report.entries} entries`}
                                    </Button>
                                </li>
                            ))}
                        </ul>
                    )}
                </Card>
            </div>
        </div>
    );
}
