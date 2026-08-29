import type { Config } from "tailwindcss";

/**
 * Qirsh Admin design tokens.
 *
 * Every value below is transcribed from the mobile product's own theme so the
 * dashboard and the app read as one product:
 *   app/lib/core/theme/app_colors.dart   → AppBrandBlue + AppColors.light
 *   app/lib/core/theme/mali_tokens.dart  → "Calm Capital" surfaces + float shadow
 *   app/lib/core/theme/app_typography.dart → IBM Plex Sans Arabic
 */
const config: Config = {
  content: [
    "./app/**/*.{ts,tsx}",
    "./components/**/*.{ts,tsx}",
    "./lib/**/*.{ts,tsx}",
  ],
  theme: {
    extend: {
      colors: {
        // AppBrandBlue — the ONE blue family, same ramp as the app.
        brand: {
          deep:   "#01102F",
          900:    "#021B79", // ★ canonical brand / logo blue
          800:    "#0A2E9E",
          700:    "#1C4FD0", // light-mode CTA
          600:    "#1C4FD0",
          500:    "#2E6BFF", // info / accent start
          400:    "#55ABFF",
          300:    "#9DB9FF",
          100:    "#EAF2FF", // ctaSoft
          50:     "#F4F7FF",
        },
        // AppColors.light surfaces
        canvas:   "#F4F6FB",
        surface:  "#FFFFFF",
        raised:   "#EEF1F7",
        muted:    "#ECEFF6",
        line:     "#DDE2EC",
        divider:  "#E8EBF2",
        hairline: "#EDF1F7",
        ink: {
          DEFAULT: "#111827",
          soft:    "#4B5563",
          faint:   "#7C879A",
        },
        // Financial semantics — untouched from the app.
        success: { DEFAULT: "#16A34A", bg: "#E8F8EE" },
        warning: { DEFAULT: "#D97706", bg: "#FFF3D8" },
        danger:  { DEFAULT: "#DC2626", bg: "#FDECEC" },
        info:    { DEFAULT: "#2E6BFF", bg: "#EAF1FF" },
        gold:    "#FBC926",
      },
      fontFamily: {
        sans: ["IBMPlexSansArabic", "system-ui", "sans-serif"],
      },
      borderRadius: {
        card: "14px",
        field: "10px",
      },
      boxShadow: {
        // MaliTokens.light.floatShadow
        float: "0 12px 40px rgba(13,30,75,.08), 0 2px 8px rgba(13,30,75,.05)",
        card: "0 1px 2px rgba(13,30,75,.04), 0 4px 16px rgba(13,30,75,.04)",
        pop: "0 20px 60px rgba(13,30,75,.16), 0 4px 12px rgba(13,30,75,.08)",
      },
      fontSize: {
        // Desktop-density scale — deliberately one step below the mobile scale.
        micro: ["11px", { lineHeight: "1.45" }],
        tiny: ["12px", { lineHeight: "1.5" }],
        sm: ["13px", { lineHeight: "1.6" }],
        base: ["14px", { lineHeight: "1.65" }],
        lg: ["16px", { lineHeight: "1.5" }],
        xl: ["19px", { lineHeight: "1.35" }],
        "2xl": ["22px", { lineHeight: "1.25" }],
        "3xl": ["28px", { lineHeight: "1.2" }],
      },
    },
  },
  plugins: [],
};

export default config;
