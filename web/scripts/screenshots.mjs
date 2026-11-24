/**
 * Captures every screen at every viewport below, from the demo build, so the
 * images are of the running application rather than a drawing of it.
 *
 * Run through `npm run screenshots`, which builds and serves first.
 */

import { mkdir } from "node:fs/promises";
import { chromium, devices } from "@playwright/test";

const BASE = process.env.SCREENSHOT_BASE ?? "http://127.0.0.1:4173";
const OUT = "../docs/screenshots";

/** Portrait sizes, plus one landscape phone and one very wide desktop. */
const targets = [
    { name: "phone", viewport: { width: 390, height: 844 }, scale: 2, touch: true },
    { name: "phone-landscape", viewport: { width: 844, height: 390 }, scale: 2, touch: true },
    { name: "tablet", viewport: { width: 820, height: 1180 }, scale: 2, touch: true },
    { name: "desktop", viewport: { width: 1440, height: 900 }, scale: 1, touch: false },
    { name: "ultrawide", viewport: { width: 2560, height: 1080 }, scale: 1, touch: false },
];

/** `full` adds a second, whole-page capture at the widest viewport only. */
const screens = [
    { name: "01-submit", path: "/" },
    { name: "02-report", path: "/r/demo", full: true },
    { name: "03-package", path: "/r/demo/p/failure" },
    { name: "04-changes", path: "/r/demo/changes" },
    { name: "05-packages", path: "/packages" },
    { name: "06-method", path: "/method" },
    { name: "07-design-system", path: "/design-system" },
];

async function capture(browser, target, theme) {
    const context = await browser.newContext({
        ...devices["Desktop Chrome"],
        viewport: target.viewport,
        deviceScaleFactor: target.scale,
        hasTouch: target.touch,
        isMobile: false,
        colorScheme: theme,
    });

    const page = await context.newPage();

    // The theme switch writes the choice to local storage, which is where the
    // application reads it from on the next load
    await page.addInitScript(
        (chosen) =>
            window.localStorage.setItem(
                "dephealth.preferences",
                JSON.stringify({ state: { theme: chosen, textScale: 1, recent: [] }, version: 0 }),
            ),
        theme,
    );

    for (const screen of screens) {
        await page.goto(`${BASE}${screen.path}`, { waitUntil: "networkidle" });

        // The demo delays its answers so the loading states are visible, and a
        // screenshot should not catch one
        await page.waitForSelector(".skeleton", { state: "detached" }).catch(() => {});
        await page.waitForTimeout(600);

        const suffix = theme === "dark" ? "-dark" : "";
        const file = `${OUT}/${target.name}/${screen.name}${suffix}.png`;

        // The viewport rather than the whole page. A full-page capture of a
        // long table on a phone is tens of thousands of pixels tall, which
        // shows the reflow no better and cannot be read at all
        await page.screenshot({ path: file });
        console.log(`wrote ${file}`);

        if (screen.full && target.name === "desktop") {
            const whole = `${OUT}/${target.name}/${screen.name}${suffix}-full.png`;
            await page.screenshot({ path: whole, fullPage: true });
            console.log(`wrote ${whole}`);
        }
    }

    await context.close();
}

const browser = await chromium.launch();

for (const target of targets) {
    await mkdir(`${OUT}/${target.name}`, { recursive: true });
    await capture(browser, target, "light");
}

// One device in the dark theme is enough to show it works, since the tokens are
// the same everywhere
await capture(
    browser,
    targets.find((t) => t.name === "desktop"),
    "dark",
);
await capture(
    browser,
    targets.find((t) => t.name === "phone"),
    "dark",
);

await browser.close();
console.log("done");
