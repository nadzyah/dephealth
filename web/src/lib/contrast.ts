/**
 * WCAG 2.1 relative luminance and contrast, used by the token test and shown on
 * the design system page so the numbers are visible rather than asserted.
 */

function channel(value: number): number {
    const c = value / 255;
    return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
}

/**
 * The channels of a hex colour, in any of the forms a stylesheet holds it. A
 * build minifies #ffffff to #fff, so a reader of the computed value cannot
 * assume six digits. An alpha is dropped rather than composited, since these
 * colours are opaque.
 */
function channels(hex: string): [number, number, number] {
    const digits = hex.trim().replace(/^#/, "");
    const full = digits.length <= 4 ? [...digits].map((digit) => digit + digit).join("") : digits;
    const [r, g, b] = [0, 2, 4].map((i) => parseInt(full.slice(i, i + 2), 16));
    return [r, g, b];
}

export function luminance(hex: string): number {
    const [r, g, b] = channels(hex);
    return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
}

export function contrastRatio(a: string, b: string): number {
    const [high, low] = [luminance(a), luminance(b)].sort((x, y) => y - x);
    return (high + 0.05) / (low + 0.05);
}

/** The value of a custom property on an element, as a hex string. */
export function tokenValue(name: string, element: Element = document.documentElement): string {
    return getComputedStyle(element).getPropertyValue(name).trim();
}
