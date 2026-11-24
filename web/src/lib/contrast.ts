/**
 * WCAG 2.1 relative luminance and contrast, used by the token test and shown on
 * the design system page so the numbers are visible rather than asserted.
 */

function channel(value: number): number {
    const c = value / 255;
    return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
}

export function luminance(hex: string): number {
    const [r, g, b] = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));
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
