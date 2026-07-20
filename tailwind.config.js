/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      fontFamily: {
        serif: ['"Playfair Display"', 'Georgia', 'serif'],
        poppins: ['Poppins', 'ui-sans-serif', 'system-ui', 'sans-serif'],
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
