import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter } from "react-router-dom";

import App from "./App";
import { logger } from "./lib/logger";
import "./styles/global.css";

// A failure outside React, which the error boundary cannot see
window.addEventListener("error", (event) => {
    logger.error("uncaught error", { message: event.message });
});

window.addEventListener("unhandledrejection", (event) => {
    logger.error("unhandled rejection", { reason: String(event.reason) });
});

const root = document.getElementById("root");
if (!root) throw new Error("the document has no #root to mount in");

createRoot(root).render(
    <StrictMode>
        {/* GitHub Pages serves the application from a subpath, which Vite puts
            in BASE_URL at build time, so the router agrees with the build */}
        <BrowserRouter basename={import.meta.env.BASE_URL}>
            <App />
        </BrowserRouter>
    </StrictMode>,
);
