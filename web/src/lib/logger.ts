/**
 * One place that writes to the console, so a message can be found, silenced or
 * pointed at a collector without hunting through components.
 *
 * Nothing here records a report token or a manifest. A token is a capability:
 * whoever holds it can read the assessment, and a log is a place things leak
 * from.
 */

type Level = "debug" | "info" | "warn" | "error";

const order: Record<Level, number> = { debug: 10, info: 20, warn: 30, error: 40 };

const threshold: number =
    order[(import.meta.env.VITE_LOG_LEVEL as Level) ?? (import.meta.env.DEV ? "debug" : "info")] ??
    order.info;

function write(level: Level, message: string, context?: Record<string, unknown>) {
    if (order[level] < threshold) return;

    const entry = {
        at: new Date().toISOString(),
        level,
        message,
        ...context,
    };

    const line = level === "debug" ? "log" : level;
    console[line as "log" | "info" | "warn" | "error"](`[dephealth] ${message}`, entry);
}

export const logger = {
    debug: (message: string, context?: Record<string, unknown>) => write("debug", message, context),
    info: (message: string, context?: Record<string, unknown>) => write("info", message, context),
    warn: (message: string, context?: Record<string, unknown>) => write("warn", message, context),
    error: (message: string, context?: Record<string, unknown>) => write("error", message, context),
};
