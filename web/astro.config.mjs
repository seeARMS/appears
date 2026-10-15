// @ts-check
import { defineConfig, fontProviders } from "astro/config";

// https://astro.build/config
export default defineConfig({
  site: "https://appea.rs",
  // Plain static files in dist/. There's no Cloudflare adapter: src/worker.ts
  // (wrangler.jsonc's main) is written by hand and only picks between the page
  // and its Markdown.
  output: "static",
  devToolbar: { enabled: false },
  server: {
    // Listen on every interface, so a phone on the same network can open the dev site.
    host: true,
    allowedHosts: [".local", ".lan", ".localdomain", ".home.arpa", ".internal"],
  },
  build: {
    // One round trip to first paint: CSS ships inside the HTML.
    inlineStylesheets: "always",
  },
  fonts: [
    {
      provider: fontProviders.fontsource(),
      name: "Instrument Serif",
      cssVariable: "--font-display",
      weights: [400],
      styles: ["normal", "italic"],
      subsets: ["latin"],
      fallbacks: ["ui-serif", "Georgia", "serif"],
    },
    {
      provider: fontProviders.fontsource(),
      name: "Hanken Grotesk",
      cssVariable: "--font-text",
      weights: ["300 700"],
      styles: ["normal"],
      subsets: ["latin"],
      fallbacks: ["ui-sans-serif", "system-ui", "sans-serif"],
    },
  ],
});
