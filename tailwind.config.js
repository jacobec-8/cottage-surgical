import colors from 'tailwindcss/colors.js'

const rgbTriple = (hex) => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16)).join(' ')

// Stock Tailwind shades, overridable inside .staff-theme (globals.css). Anywhere
// else the variable is unset, so the fallback renders exactly the stock color.
const themeable = (family) =>
  Object.fromEntries(
    Object.entries(colors[family]).map(([shade, hex]) => [
      shade,
      `rgb(var(--staff-${family}-${shade}, ${rgbTriple(hex)}) / <alpha-value>)`,
    ]),
  )

/** @type {import('tailwindcss').Config} */
const tailwindConfig = {
  content: ['./src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      fontFamily: {
        // Match the real Cottage Pharmacy Rx site: Montserrat headings + Source
        // Sans body. Clean/corporate — deliberately not the "feely round" look.
        sans: ['var(--font-source-sans)', '"Source Sans 3"', 'ui-sans-serif', 'system-ui', 'sans-serif'],
        heading: ['var(--font-montserrat)', 'Montserrat', 'ui-sans-serif', 'system-ui', 'sans-serif'],
        // Back-compat aliases so existing font-serif / font-poppins classes across
        // the storefront now render the brand fonts (no per-file sweep needed).
        serif: ['var(--font-montserrat)', 'Montserrat', 'ui-sans-serif', 'sans-serif'],
        poppins: ['var(--font-source-sans)', '"Source Sans 3"', 'ui-sans-serif', 'sans-serif'],
      },
      borderRadius: {
        md: 'var(--staff-radius-md, 0.375rem)',
        lg: 'var(--staff-radius-lg, 0.5rem)',
        xl: 'var(--staff-radius-xl, 0.75rem)',
        '2xl': 'var(--staff-radius-2xl, 1rem)',
      },
      colors: {
        slate: themeable('slate'),
        blue: themeable('blue'),
        emerald: themeable('emerald'),
        red: themeable('red'),
        amber: themeable('amber'),
        violet: themeable('violet'),
        purple: themeable('purple'),
        navy: { DEFAULT: '#16294d', 800: '#1b3157', 700: '#254070' },
        terracotta: { DEFAULT: '#c1683a', 600: '#ad5c33' },
        cream: '#f7f3ec',
        peach: '#e3a97c',
        // JustWalkers-style clinical retail blue (landing redesign)
        brand: {
          50: '#eef3fb',
          100: '#dbe6f5',
          200: '#bcd0ea',
          500: '#5273b8',
          600: '#45619c',
          700: '#3a4f80',
        },
      },
    },
  },
  plugins: [],
}

export default tailwindConfig
