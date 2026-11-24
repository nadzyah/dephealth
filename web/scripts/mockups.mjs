/**
 * Renders the interface design document to PDF, which is the form the Adaptive
 * UI criterion accepts. The page styles declare A4 and their own margins, so
 * the size comes from the document rather than from here.
 *
 * Run through `npm run mockups`, or through `make mockups` from the repository
 * root, which runs it in the Playwright image.
 */

import { chromium } from "@playwright/test";

const source = new URL("../../docs/mockups/index.html", import.meta.url);
const out = new URL("../../docs/mockups/dephealth-interface-design.pdf", import.meta.url);

const browser = await chromium.launch();
const page = await browser.newPage();

const missing = [];
page.on("requestfailed", (request) => missing.push(request.url()));

await page.goto(source.href, { waitUntil: "networkidle" });

// A screen plate that failed to load would leave a labelled empty frame in the
// document, which is worse than a failure here
const broken = await page.evaluate(() =>
    [...document.images].filter((image) => !image.naturalWidth).map((image) => image.src),
);

await page.pdf({
    path: out.pathname,
    format: "A4",
    printBackground: true,
    preferCSSPageSize: true,
});

await browser.close();

if (broken.length || missing.length) {
    console.error("these assets did not load:");
    for (const url of new Set([...broken, ...missing])) console.error(`  ${url}`);
    process.exit(1);
}

console.log(`wrote ${out.pathname}`);
