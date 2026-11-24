/**
 * The API answers every failure with an RFC 9457 problem document. This is that
 * document as an error the application can branch on, which is what keeps the
 * HTTP status out of the components.
 */

export interface ProblemBody {
    type: string;
    title: string;
    status: number;
    detail: string;
    [key: string]: unknown;
}

export class ApiProblem extends Error {
    readonly type: string;
    readonly title: string;
    readonly status: number;
    readonly detail: string;
    readonly body: ProblemBody;

    constructor(body: ProblemBody) {
        super(`${body.title}: ${body.detail}`);
        this.name = "ApiProblem";
        this.type = body.type;
        this.title = body.title;
        this.status = body.status;
        this.detail = body.detail;
        this.body = body;
    }

    /** The identifier without its path, which is what the views switch on. */
    get slug(): string {
        return this.type.replace(/^.*\//, "");
    }

    /** A number the problem carried, such as the line a manifest failed on. */
    field<T>(name: string): T | undefined {
        return this.body[name] as T | undefined;
    }

    /** Nothing the reader can do differently, so the message offers no remedy. */
    get isServerFault(): boolean {
        return this.status >= 500;
    }

    get isNotFound(): boolean {
        return this.status === 404;
    }

    get isGone(): boolean {
        return this.status === 410;
    }

    /**
     * Built for a response that carried no problem document, which is what a
     * proxy or a network failure produces.
     */
    static fromStatus(status: number, statusText: string): ApiProblem {
        const titles: Record<number, string> = {
            401: "Authentication required",
            403: "Not permitted",
            404: "Not found",
            413: "The request is too large",
            429: "Too many requests",
            500: "The service failed",
            502: "The service is unreachable",
            503: "The service is unavailable",
            504: "The service did not answer in time",
        };

        return new ApiProblem({
            type: `/problems/http-${status}`,
            title: titles[status] ?? "The request failed",
            status,
            detail:
                status >= 500
                    ? "The service answered with an error. Trying again in a moment may work."
                    : statusText || `The service answered ${status}.`,
        });
    }

    static network(detail: string): ApiProblem {
        return new ApiProblem({
            type: "/problems/network",
            title: "The service could not be reached",
            status: 0,
            detail,
        });
    }
}
