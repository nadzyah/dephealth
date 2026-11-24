/**
 * Lets the reader choose the theme and the text size, which the Adaptive UI
 * criterion asks for beyond following the system preference.
 *
 * A details element rather than a custom menu, so it opens with the keyboard,
 * closes with Escape and needs no focus trapping.
 */

import {
    selectTextScale,
    selectTheme,
    useAppStore,
    type TextScale,
    type ThemeChoice,
} from "../../store/useAppStore";
import { SettingsIcon } from "../ui/icons";

import "./Appearance.css";

const themes: { value: ThemeChoice; label: string }[] = [
    { value: "system", label: "System" },
    { value: "light", label: "Light" },
    { value: "dark", label: "Dark" },
];

const scales: { value: TextScale; label: string }[] = [
    { value: 1, label: "100%" },
    { value: 1.125, label: "112%" },
    { value: 1.25, label: "125%" },
];

export function Appearance() {
    const theme = useAppStore(selectTheme);
    const textScale = useAppStore(selectTextScale);
    const setTheme = useAppStore((state) => state.setTheme);
    const setTextScale = useAppStore((state) => state.setTextScale);

    return (
        <details className="appearance">
            <summary aria-label="Appearance settings">
                <SettingsIcon />
                <span className="appearance-summary-label">Appearance</span>
            </summary>

            <div className="appearance-panel">
                <fieldset>
                    <legend>Theme</legend>
                    <div className="appearance-choices">
                        {themes.map(({ value, label }) => (
                            <label key={value} className="appearance-choice">
                                <input
                                    type="radio"
                                    name="theme"
                                    value={value}
                                    checked={theme === value}
                                    onChange={() => setTheme(value)}
                                />
                                <span>{label}</span>
                            </label>
                        ))}
                    </div>
                </fieldset>

                <fieldset>
                    <legend>Text size</legend>
                    <div className="appearance-choices">
                        {scales.map(({ value, label }) => (
                            <label key={value} className="appearance-choice">
                                <input
                                    type="radio"
                                    name="text-scale"
                                    value={value}
                                    checked={textScale === value}
                                    onChange={() => setTextScale(value)}
                                />
                                <span>{label}</span>
                            </label>
                        ))}
                    </div>
                </fieldset>
            </div>
        </details>
    );
}
