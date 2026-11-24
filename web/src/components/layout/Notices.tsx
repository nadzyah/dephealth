/**
 * The notices any screen can raise, shown in one place. A live region, so a
 * screen reader hears a failure that happened somewhere the reader was not
 * looking.
 */

import { useAppStore, selectNotices } from "../../store/useAppStore";
import { CheckIcon, CloseIcon, WarningIcon } from "../ui/icons";

import "./Notices.css";

export function Notices() {
    const notices = useAppStore(selectNotices);
    const dismiss = useAppStore((state) => state.dismiss);

    return (
        <div className="notices" role="region" aria-label="Notices" aria-live="polite">
            {notices.map((notice) => (
                <div className={`notice ${notice.kind}`} key={notice.id}>
                    {notice.kind === "error" ? <WarningIcon /> : <CheckIcon />}
                    <div className="notice-text">
                        <strong>{notice.title}</strong>
                        {notice.detail && <span className="small">{notice.detail}</span>}
                    </div>
                    <button
                        type="button"
                        className="notice-close"
                        onClick={() => dismiss(notice.id)}
                        aria-label={`Dismiss: ${notice.title}`}
                    >
                        <CloseIcon size="1em" />
                    </button>
                </div>
            ))}
        </div>
    );
}
