import { Link } from "react-router-dom";

import { Empty } from "../components/ui/States";

export default function NotFoundPage() {
    return (
        <Empty title="Page Not Found" level={1}>
            <p className="muted">
                Nothing here answers that address. A report link looks like <code>/r/</code>{" "}
                followed by its token.
            </p>
            <Link to="/" className="button secondary touchable">
                Go to the home page
            </Link>
        </Empty>
    );
}
