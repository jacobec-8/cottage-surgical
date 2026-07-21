/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      fontFamily: {
        // Match the real Cottage Pharmacy Rx site: Montserrat headings + Source
        // Sans body. Clean/corporate — deliberately not the "feely round" look.
        sans: ['"Source Sans 3"', '"Source Sans Pro"', 'ui-sans-serif', 'system-ui', 'sans-serif'],
        heading: ['Montserrat', 'ui-sans-serif', 'system-ui', 'sans-serif'],
        // Back-compat aliases so existing font-serif / font-poppins classes across
        // the storefront now render the brand fonts (no per-file sweep needed).
        serif: ['Montserrat', 'ui-sans-serif', 'sans-serif'],
        poppins: ['"Source Sans 3"', '"Source Sans Pro"', 'ui-sans-serif', 'sans-serif'],
      },
      colors: {
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
