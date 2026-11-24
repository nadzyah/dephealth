import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";

import { FileDrop } from "./FileDrop";

function fileOf(name: string, contents: string): File {
    return new File([contents], name, { type: "text/plain" });
}

describe("FileDrop", () => {
    it("hands over the file and its text once it passes validation", async () => {
        const onFile = vi.fn();
        render(<FileDrop onFile={onFile} />);

        const input = screen.getByLabelText("Choose a lockfile");
        await userEvent.upload(input, fileOf("Cargo.lock", "version = 4\n"));

        expect(onFile).toHaveBeenCalledTimes(1);
        expect(onFile.mock.calls[0][1]).toBe("version = 4\n");
    });

    it("reports a rejection in place and sends nothing", async () => {
        const onFile = vi.fn();
        render(<FileDrop onFile={onFile} />);

        const input = screen.getByLabelText("Choose a lockfile");
        await userEvent.upload(input, fileOf("holiday.png", "x"));

        expect(onFile).not.toHaveBeenCalled();
        expect(await screen.findByRole("alert")).toHaveTextContent("does not look like a lockfile");
        expect(input).toHaveAttribute("aria-invalid", "true");
    });

    it("shows a failure the service reported, not only its own", () => {
        render(<FileDrop onFile={vi.fn()} error="The manifest could not be read at line 14." />);

        expect(screen.getByRole("alert")).toHaveTextContent("line 14");
    });

    it("disables the control while an assessment is in flight", () => {
        render(<FileDrop onFile={vi.fn()} busy />);

        expect(screen.getByRole("button", { name: /assessing/i })).toBeDisabled();
        expect(screen.getByLabelText("Choose a lockfile")).toBeDisabled();
    });
});
