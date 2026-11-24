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
