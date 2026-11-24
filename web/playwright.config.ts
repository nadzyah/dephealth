import { defineConfig, devices } from "@playwright/test";

/**
 * The end to end tests run against the demo build, so they need neither the API
 * nor a database. What they exercise is the application: routing, the request
 * layer, the states, and the screens a reader moves through.
 *
 * Two viewports, because the layout is not the same at both and the navigation
 * moves from the header to a bar at the bottom.
 */
export default defineConfig({
    testDir: "./e2e",
    fullyParallel: true,
    forbidOnly: !!process.env.CI,
    retries: process.env.CI ? 1 : 0,
    reporter: process.env.CI ? [["github"], ["list"]] : [["list"]],

    use: {
        baseURL: "http://127.0.0.1:4173",
        trace: "retain-on-failure",
    },

    projects: [
        { name: "desktop", use: { ...devices["Desktop Chrome"] } },
        { name: "phone", use: { ...devices["Pixel 7"] } },
    ],

    webServer: {
        command: "npm run build:demo && npm run preview -- --port 4173 --host 127.0.0.1",
        url: "http://127.0.0.1:4173",
        reuseExistingServer: !process.env.CI,
        timeout: 120_000,
    },
});
