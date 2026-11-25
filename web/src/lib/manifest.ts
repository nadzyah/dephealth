/**
 * What can be decided about a submission in the browser, before anything is
 * sent. Nothing here parses a lockfile: whether the contents are one is the
 * service's judgement, and it answers with the line the parse stopped at.
 */

/** The service refuses anything larger, so there is no point sending it. */
export const MAX_BYTES = 2 * 1024 * 1024;

const ACCEPTED_NAMES = ["cargo.lock"];
const ACCEPTED_EXTENSIONS = [".lock", ".toml", ".txt"];

export interface FileRejection {
    reason: "empty" | "too-large" | "wrong-kind";
    message: string;
}

export function validateFile(file: File): FileRejection | undefined {
    if (file.size === 0) {
        return { reason: "empty", message: "That file is empty." };
    }

    if (file.size > MAX_BYTES) {
        const megabytes = (file.size / 1024 / 1024).toFixed(1);
        return {
            reason: "too-large",
            message: `That file is ${megabytes} MB and the service accepts 2 MB.`,
        };
    }

    const name = file.name.toLowerCase();

    // The two files sit side by side and carry similar names, so the one a
    // submitter is most likely to pick by mistake is named here rather than
    // sent for the service to refuse
    if (name === "cargo.toml") {
        return {
            reason: "wrong-kind",
            message:
                "Cargo.toml is the manifest. Submit Cargo.lock from the same directory, " +
                "which lists the versions Cargo resolved.",
        };
    }

    const looksRight =
        ACCEPTED_NAMES.includes(name) ||
        ACCEPTED_EXTENSIONS.some((extension) => name.endsWith(extension));

    if (!looksRight) {
        return {
            reason: "wrong-kind",
            message: `${file.name} does not look like a lockfile. Choose Cargo.lock, or a .lock, .toml or .txt file.`,
        };
    }

    return undefined;
}

/**
 * The project a lockfile belongs to, when the file says. A package with no
 * `source` is resolved locally rather than from a registry, which is the
 * submitting project or a member of its workspace. Cargo lists packages
 * alphabetically, so a workspace of several is named by its first member.
 *
 * This is the one thing read from the file in the browser, and it is read for
 * a label rather than for the assessment. Whether the contents are a lockfile
 * remains the service's judgement.
 */
export function projectName(lockfile: string): string | undefined {
    for (const block of lockfile.split(/^\[\[package\]\]/m).slice(1)) {
        const body = block.split(/^\[/m)[0];
        if (/^\s*source\s*=/m.test(body)) continue;

        const name = /^\s*name\s*=\s*"([^"]+)"/m.exec(body);
        if (name) return name[1];
    }
    return undefined;
}

/**
 * The token out of a permanent link, accepting either the whole link or the
 * token on its own. Anything else is refused rather than sent, since a request
 * for it could only come back as a 404.
 */
export function tokenFromLink(value: string): string | undefined {
    const trimmed = value.trim().replace(/\/+$/, "");
    if (!trimmed) return undefined;

    const candidate = trimmed.includes("/") ? trimmed.split("/").pop() : trimmed;
    if (!candidate) return undefined;

    return /^[0-9a-f]{64}$/i.test(candidate) || candidate === "demo" ? candidate : undefined;
}
