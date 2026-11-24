import react from "@vitejs/plugin-react";
import { defineConfig } from "vitest/config";

export default defineConfig({
    plugins: [react()],

    // GitHub Pages serves the application from a repository subpath, so the
    // base is set at build time rather than assumed to be the root
    base: process.env.VITE_BASE ?? "/",

    build: {
        outDir: "dist",
        sourcemap: true,
    },

    test: {
        environment: "jsdom",
        globals: true,
        setupFiles: ["./src/test/setup.ts"],

        // Only the unit tests. The specs under e2e/ are Playwright's, and they
        // need a browser rather than jsdom
        include: ["src/**/*.test.{ts,tsx}"],
        coverage: {
            provider: "v8",
            reporter: ["text", "html"],
            include: ["src/**/*.{ts,tsx}"],
            exclude: ["src/**/*.test.{ts,tsx}", "src/test/**", "src/main.tsx"],
        },
    },
});
