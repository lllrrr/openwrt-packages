export interface ThemeColors {
  isDark: boolean;
  selectionBg: string;
  lineNumberColor: string;
}

/**
 * Detects the current theme (dark/light mode) based on body background color
 * and returns appropriate color values for UI elements.
 *
 * This function analyzes the computed background color of the document body
 * to determine if the current theme is dark or light, then returns suitable
 * colors for selection backgrounds and line numbers that work well with
 * the detected theme.
 *
 * @returns {ThemeColors} Object containing theme information and color values
 */
export function getThemeColors(): ThemeColors {
  try {
    const bodyBg = getComputedStyle(document.body).backgroundColor;
    const match = bodyBg.match(/rgba?\((\d+),\s*(\d+),\s*(\d+)/);
    if (match) {
      const r = parseInt(match[1], 10);
      const g = parseInt(match[2], 10);
      const b = parseInt(match[3], 10);
      const luminance = 0.299 * r + 0.587 * g + 0.114 * b;
      const isDark = luminance < 128;

      return {
        isDark,
        selectionBg: isDark ? "rgba(66, 165, 245, 0.2)" : "#e3f2fd",
        lineNumberColor: isDark ? "#aaa" : "#999",
      };
    }
  } catch (_e) {
    console.warn("Failed to detect theme, using light mode defaults");
  }

  return {
    isDark: false,
    selectionBg: "#e3f2fd",
    lineNumberColor: "#999",
  };
}
