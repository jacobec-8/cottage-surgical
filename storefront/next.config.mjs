/** @type {import('next').NextConfig} */
const nextConfig = {
  // Don't fail the production build on type/lint nits (consistent with the Vite app).
  typescript: { ignoreBuildErrors: true },
  eslint: { ignoreDuringBuilds: true },
}

export default nextConfig
