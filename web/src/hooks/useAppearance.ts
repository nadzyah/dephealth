/**
 * Applies what the reader chose about appearance to the document.
 *
 * The theme is an attribute on the root element, which tokens.css reads, so
 * "system" means no attribute and the preference media query decides. The text
 * scale is the root font size, which every length in the stylesheet is relative
 * to, so one number resizes the whole interface without a second set of rules.
 */

import { useEffect } from "react";

import { selectTextScale, selectTheme, useAppStore } from "../store/useAppStore";

export function useAppearance(): void {
    const theme = useAppStore(selectTheme);
    const textScale = useAppStore(selectTextScale);

    useEffect(() => {
        const root = document.documentElement;
        if (theme === "system") {
            delete root.dataset.theme;
        } else {
            root.dataset.theme = theme;
        }
    }, [theme]);

    useEffect(() => {
        document.documentElement.style.fontSize = `${textScale * 100}%`;
    }, [textScale]);
}
