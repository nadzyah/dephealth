/**
 * Routes and the shell around them.
 *
 * Every screen but the first is loaded on demand, so opening the submission
 * page does not download the chart code or the design system with it. The
 * submission page is in the first chunk because it is where a visitor lands.
 */

import { Suspense, lazy } from "react";
import { Route, Routes } from "react-router-dom";

import { AppShell } from "./components/layout/AppShell";
import { ErrorBoundary } from "./components/ErrorBoundary";
import { Loading } from "./components/ui/States";
import { useAppearance } from "./hooks/useAppearance";
import SubmitPage from "./pages/SubmitPage";

const ReportPage = lazy(() => import("./pages/ReportPage"));
const PackagePage = lazy(() => import("./pages/PackagePage"));
const ChangesPage = lazy(() => import("./pages/ChangesPage"));
const PackagesPage = lazy(() => import("./pages/PackagesPage"));
const MethodPage = lazy(() => import("./pages/MethodPage"));
const DesignSystemPage = lazy(() => import("./pages/DesignSystemPage"));
const NotFoundPage = lazy(() => import("./pages/NotFoundPage"));

export default function App() {
    useAppearance();

    return (
        <AppShell>
            <ErrorBoundary>
                <Suspense fallback={<Loading label="Loading this screen" />}>
                    <Routes>
                        <Route path="/" element={<SubmitPage />} />
                        <Route path="/r/:token" element={<ReportPage />} />
                        <Route path="/r/:token/changes" element={<ChangesPage />} />
                        <Route path="/r/:token/p/:name" element={<PackagePage />} />
                        <Route path="/packages" element={<PackagesPage />} />
                        <Route path="/method" element={<MethodPage />} />
                        <Route path="/design-system" element={<DesignSystemPage />} />
                        <Route path="*" element={<NotFoundPage />} />
                    </Routes>
                </Suspense>
            </ErrorBoundary>
        </AppShell>
    );
}
