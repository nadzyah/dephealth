/**
 * The submission control: a file input that also accepts a drop, with the
 * validation that can be done in the browser before anything is sent.
 *
 * What is checked here is only what is cheap and certain: that there is a file,
 * that it is not absurdly large, and that it is text. Whether the contents are a
 * lockfile is the service's judgement, and it answers with the line the parse
 * stopped at, which no amount of guessing here would improve on.
 */

import { useId, useRef, useState, type DragEvent } from "react";

import { validateFile } from "../lib/manifest";
import { Button } from "./ui/Button";
import { UploadIcon } from "./ui/icons";

import "./FileDrop.css";

interface FileDropProps {
    onFile: (file: File, text: string) => void;
    busy?: boolean;
    /** Shown under the control, for a failure the service reported. */
    error?: string;
}

export function FileDrop({ onFile, busy = false, error }: FileDropProps) {
    const inputId = useId();
    const describedById = useId();
    const input = useRef<HTMLInputElement>(null);

    const [over, setOver] = useState(false);
    const [rejection, setRejection] = useState<string | undefined>(undefined);
    const [accepted, setAccepted] = useState<string | undefined>(undefined);

    async function accept(file: File | undefined) {
        if (!file) return;

        const problem = validateFile(file);
        if (problem) {
            setRejection(problem.message);
            setAccepted(undefined);
            return;
        }

        setRejection(undefined);
        setAccepted(file.name);
        onFile(file, await file.text());
    }

    function onDrop(event: DragEvent<HTMLDivElement>) {
        event.preventDefault();
        setOver(false);
        void accept(event.dataTransfer.files?.[0]);
    }

    const message = rejection ?? error;

    return (
        <div className="file-drop-wrap">
            <div
                className={["file-drop", over ? "over" : "", message ? "invalid" : ""]
                    .filter(Boolean)
                    .join(" ")}
                onDragOver={(event) => {
                    event.preventDefault();
                    setOver(true);
                }}
                onDragLeave={() => setOver(false)}
                onDrop={onDrop}
            >
                <UploadIcon size="2em" />

                <label htmlFor={inputId} className="file-drop-label">
                    Choose a lockfile
                </label>

                <p className="muted small" id={describedById}>
                    Drop <code>Cargo.lock</code> here, or choose it. Up to 2 MB. The file is read,
                    assessed and discarded.
                </p>

                <input
                    ref={input}
                    id={inputId}
                    className="visually-hidden"
                    type="file"
                    accept=".lock,.toml,.txt,text/plain"
                    aria-describedby={describedById}
                    aria-invalid={message ? true : undefined}
                    disabled={busy}
                    onChange={(event) => void accept(event.target.files?.[0])}
                />

                <div className="row">
                    <Button
                        variant="primary"
                        busy={busy}
                        onClick={() => input.current?.click()}
                        iconBefore={<UploadIcon size="1em" />}
                    >
                        {busy ? "Assessing" : "Choose a file"}
                    </Button>
                    {accepted && !message && (
                        <span className="small muted wrap-anywhere">{accepted}</span>
                    )}
                </div>
            </div>

            {message && (
                <p className="file-drop-error" role="alert">
                    {message}
                </p>
            )}
        </div>
    );
}
