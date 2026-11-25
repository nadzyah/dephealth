import { expect, test } from "@playwright/test";

/**
 * The responsive claims are checkable, so they are checked here rather than
 * asserted in a document: navigation reachable at every width, no horizontal
 * overflow, touch targets at 44 pixels, and a layout that survives an
 * orientation change and browser zoom.
 */

const widths = [
    { name: "phone", width: 390, height: 844 },
    { name: "phone landscape", width: 844, height: 390 },
    { name: "tablet", width: 820, height: 1180 },
    { name: "desktop", width: 1440, height: 900 },
    { name: "ultrawide", width: 2560, height: 1080 },
];

test.describe("every width", () => {
    for (const viewport of widths) {
        test(`${viewport.name} keeps the navigation and does not scroll sideways`, async ({
            page,
        }) => {
            await page.setViewportSize({ width: viewport.width, height: viewport.height });
            await page.goto("/r/demo");

            // One of the two navigations is visible, never neither
            const links = page.getByRole("navigation").getByRole("link", { name: "Packages" });
            await expect(links.filter({ visible: true })).toHaveCount(1);

            // Nothing overflows the viewport
            const overflow = await page.evaluate(
                () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
            );
            expect(overflow).toBeLessThanOrEqual(0);
        });
    }
});

test("a touch target is at least 44 pixels on a phone", async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto("/r/demo");

    const filter = page.getByRole("radio", { name: "Unresolved" });
    const box = await filter.locator("..").boundingBox();

    expect(box?.height ?? 0).toBeGreaterThanOrEqual(44);
});

test("the layout survives browser zoom", async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto("/r/demo");

    // Zoom, as the browser's own control does it, by growing the root font size
    await page.evaluate(() => {
        document.documentElement.style.fontSize = "200%";
    });

    const overflow = await page.evaluate(
        () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
    );
    expect(overflow).toBeLessThanOrEqual(0);
    await expect(page.getByRole("heading", { level: 1 })).toBeVisible();
});

test("the theme can be chosen and is remembered", async ({ page }) => {
    await page.goto("/");

    // A summary element is a disclosure triangle rather than a button, so it is
    // found by its accessible name rather than by a role
    await page.getByLabel("Appearance settings").click();
    await page.getByRole("radio", { name: "Dark" }).check();

    await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");

    await page.reload();
    await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
});

test("rows in the design system stay apart when the text is doubled", async ({ page }) => {
    await page.goto("/design-system");

    // Doubling the root font size is how a browser applies zoom, and it is the
    // case where a fixed grid column puts one part of a row over another
    await page.addStyleTag({ content: "html { font-size: 200% }" });

    const overlapping = await page.evaluate(() => {
        const found: string[] = [];
        for (const row of document.querySelectorAll(".swatches li")) {
            const parts = [...row.children].map((part) => part.getBoundingClientRect());
            parts.forEach((a, i) =>
                parts.slice(i + 1).forEach((b) => {
                    if (
                        a.left < b.right &&
                        b.left < a.right &&
                        a.top < b.bottom &&
                        b.top < a.bottom
                    ) {
                        found.push((row.textContent ?? "").trim().slice(0, 24));
                    }
                }),
            );
        }
        return found;
    });

    expect(overlapping).toEqual([]);
});
