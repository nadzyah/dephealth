import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { ExternalLink } from "./ExternalLink";

describe("a link that leaves the application", () => {
    it("opens in a new tab without handing it a reference back", () => {
        render(<ExternalLink href="https://example.com/repo">Repository</ExternalLink>);

        const link = screen.getByRole("link");
        expect(link).toHaveAttribute("target", "_blank");

        // Without noopener the opened page can navigate this one through
        // window.opener, which is the reason the attribute is here
        expect(link.getAttribute("rel")).toContain("noopener");
        expect(link.getAttribute("rel")).toContain("noreferrer");
    });

    it("says where it goes, for a reader who does not see the mark", () => {
        render(<ExternalLink href="https://example.com/repo">Repository</ExternalLink>);
        expect(screen.getByRole("link").textContent).toContain("opens in a new tab");
    });
});
