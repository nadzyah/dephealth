import { Link } from "react-router-dom";

import { Empty } from "../components/ui/States";

export default function NotFoundPage() {
    return (
        <Empty title="No such page">
            <p className="muted">
                Nothing here answers that address. A report link looks like <code>/r/</code>{" "}
                followed by its token.
            </p>
            <Link to="/">Assess a manifest</Link>
        </Empty>
    );
}
