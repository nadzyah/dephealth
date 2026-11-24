import { expect, test } from "@playwright/test";

/**
 * The path a technical lead takes: submit a lockfile, read the ranked tree,
 * open the evidence behind the entry at the top.
 */
test("a submitted manifest becomes a ranked tree with evidence behind each entry", async ({
    page,
}) => {
    await page.goto("/");

    await expect(page.getByRole("heading", { name: "Dependency Assessment" })).toBeVisible();

    // The control takes a file rather than a path, so the file is supplied in
    // memory rather than from the repository
    await page.getByLabel("Choose a lockfile").setInputFiles({
        name: "Cargo.lock",
        mimeType: "text/plain",
        buffer: Buffer.from(
            [
                "version = 4",
                "",
                "[[package]]",
                'name = "my-service"',
                'version = "0.1.0"',
                'dependencies = ["serde"]',
                "",
                "[[package]]",
                'name = "serde"',
                'version = "1.0.228"',
                'source = "registry+https://github.com/rust-lang/crates.io-index"',
            ].join("\n"),
        ),
    });

    // The report opens at its permanent link
    await expect(page).toHaveURL(/\/r\/demo$/);
    await expect(page.getByRole("heading", { level: 1 })).toContainText("Dependencies");

    // The age of both sources travels with the figures
    await expect(page.getByText("Source Data")).toBeVisible();
    await expect(page.getByText("Repository events")).toBeVisible();

    // Ranked, so the worst entry is the first row of the body. The header row
    // exists only above the phone breakpoint, so the body is addressed rather
    // than an index into every row
    const body = page.getByRole("rowgroup").last();
    await expect(body.getByRole("row").first()).toContainText("failure");

    await page.getByRole("link", { name: "failure", exact: true }).click();

    await expect(page).toHaveURL(/\/r\/demo\/p\/failure$/);
    await expect(page.getByRole("heading", { level: 1 })).toContainText("failure");

    // The evidence: the series, the activity, and what moved the score
    await expect(page.getByRole("img", { name: /Daily downloads of failure/ })).toBeVisible();
    await expect(page.getByText("Days since the last event")).toBeVisible();
    await expect(page.getByText("Days since the last development event")).toBeVisible();
    await expect(page.getByText("raised the risk").first()).toBeVisible();
});

test("the tree can be searched and filtered down to the entries without a score", async ({
    page,
}) => {
    await page.goto("/r/demo");

    const count = page.getByRole("status");
    await expect(count).toHaveText("39 entries");

    await page.getByLabel("Search the tree by package name").fill("serde");
    await expect(count).toHaveText(/of 39 entries$/);

    await page.getByLabel("Search the tree by package name").fill("");
    await page.getByRole("radio", { name: "Unresolved" }).click();
    await expect(count).toHaveText("35 of 39 entries");

    await expect(page.getByText("Not published on the registry").first()).toBeVisible();
});

test("a link that addresses no report is refused with a reason, not a blank page", async ({
    page,
}) => {
    await page.goto(`/r/${"0".repeat(64)}`);

    const alert = page.getByRole("alert");
    await expect(alert).toContainText("No such report");

    // The problem identifier belongs in the response and the log. On the screen
    // it is a code the reader can neither act on nor look up
    await expect(alert).not.toContainText("report-not-found");

    // One action. Repeating a request for a link that addresses nothing cannot
    // change the answer, so no retry is offered beside it
    await expect(page.getByRole("link", { name: /go to home page/i })).toBeVisible();
    await expect(page.getByRole("button", { name: /try again/i })).toHaveCount(0);
});

test("a package in the list opens its current assessment", async ({ page }) => {
    await page.goto("/packages");

    // The list is the only route to a package that is not in a report, so a row
    // that does not address one is a dead end
    const first = page.locator("ul.packages a").first();
    const name = (await first.innerText()).split(" ")[0];
    await first.click();

    await expect(page).toHaveURL(new RegExp(`/p/${name}$`));
    await expect(page.getByRole("heading", { level: 1 })).toContainText(name);
    await expect(page.getByRole("heading", { name: "Downloads" })).toBeVisible();

    // The screen states which figures these are, since a report holds different ones
    await expect(page.getByText("The figures on this screen are the current ones")).toBeVisible();
});
