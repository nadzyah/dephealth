/**
 * The last line of defence. A render that throws takes the whole tree down with
 * it, leaving a blank page, so the boundary catches it, logs it and offers the
 * reader a way out.
 *
 * Failures from the API do not come through here. Those are values, handled by
 * the screen that made the request, which is why they can say something useful
 * about what failed. This is for a programming fault.
 */

import { Component, type ErrorInfo, type ReactNode } from "react";

import { logger } from "../lib/logger";
import { Button } from "./ui/Button";
import { WarningIcon } from "./ui/icons";

interface Props {
    children: ReactNode;
}

interface State {
    error: Error | undefined;
}

export class ErrorBoundary extends Component<Props, State> {
    state: State = { error: undefined };

    static getDerivedStateFromError(error: Error): State {
        return { error };
    }

    componentDidCatch(error: Error, info: ErrorInfo) {
        logger.error("a component failed to render", {
            error: error.message,
            component: info.componentStack?.split("\n")[1]?.trim(),
        });
    }

    render() {
        const { error } = this.state;
        if (!error) return this.props.children;

        return (
            <div className="container">
                <div className="state failure" role="alert">
                    <WarningIcon size="1.75em" />
                    <h1>Unexpected Error</h1>
                    <p>
                        The fault is in the application rather than in your request, and it has been
                        logged to the browser console. Reloading usually clears it.
                    </p>
                    <div className="row state-actions">
                        <Button variant="primary" onClick={() => window.location.reload()}>
                            Reload the page
                        </Button>
                        <a className="button secondary touchable" href="/">
                            Start again
                        </a>
                    </div>
                    <code className="small muted wrap-anywhere">{error.message}</code>
                </div>
            </div>
        );
    }
}
