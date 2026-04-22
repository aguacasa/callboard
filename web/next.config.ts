import type { NextConfig } from "next";

const apiOrigin = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:3000";

const csp = [
  "default-src 'self'",
  "img-src 'self' data: https:",
  "font-src 'self' https://fonts.gstatic.com data:",
  "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
  // 'unsafe-inline' + 'unsafe-eval' are required by Next.js runtime;
  // tighten to nonce-based once you're ready to wire that up.
  "script-src 'self' 'unsafe-inline' 'unsafe-eval'",
  `connect-src 'self' ${apiOrigin}`,
  "frame-ancestors 'none'",
  "base-uri 'self'",
  "form-action 'self'",
].join("; ");

const nextConfig: NextConfig = {
  // Emit a minimal standalone server at .next/standalone for the Docker image.
  output: "standalone",
  poweredByHeader: false,

  // The backend at the repo root has its own package-lock.json, so Next's
  // auto-detection picks that parent directory as the workspace root and
  // Turbopack can't resolve next/ from web/node_modules. Pin the root here.
  turbopack: {
    root: __dirname,
  },

  async headers() {
    return [
      {
        source: "/:path*",
        headers: [
          { key: "Content-Security-Policy", value: csp },
          { key: "Strict-Transport-Security", value: "max-age=63072000; includeSubDomains; preload" },
          { key: "X-Content-Type-Options", value: "nosniff" },
          { key: "X-Frame-Options", value: "DENY" },
          { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
          { key: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=()" },
        ],
      },
    ];
  },
};

export default nextConfig;
