// The Worker in front of the static site. It only sees the paths in
// wrangler.jsonc's assets.run_worker_first (pages and app downloads); every
// other file is served straight from dist/.
//
// The page has a Markdown version built beside it (/index.md). It's served at
// that address, and at / when the request's Accept header prefers
// text/markdown (src/lib/negotiate.ts). Browsers never ask for Markdown, so
// they always get the HTML.

import { prefersMarkdown } from "./lib/negotiate";
import { SITE } from "./site";
import { download } from "./lib/download";
import type { R2Bucket } from "@cloudflare/workers-types";

interface Env {
  ASSETS: { fetch: (input: Request | URL | string, init?: RequestInit) => Promise<Response> };
  DOWNLOADS: R2Bucket;
}
interface WorkerCache {
  match(request: Request): Promise<Response | undefined>;
  put(request: Request, response: Response): Promise<void>;
}
declare const caches: { default: WorkerCache };

export default {
  async fetch(request: Request, env: Env, ctx: { waitUntil(task: Promise<unknown>): void }): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/app.dmg" || url.pathname.startsWith("/downloads/") || url.pathname.startsWith("/models/")) {
      const cacheable = url.pathname.startsWith("/downloads/") && request.method === "GET" &&
        !["range", "if-range", "if-none-match", "if-modified-since"].some((header) => request.headers.has(header));
      if (cacheable) {
        const cached = await caches.default.match(request);
        if (cached) return cached;
      }
      const response = await download(request, env.DOWNLOADS);
      // The thin app fits in the standard edge cache. Larger model files stream
      // straight from R2; never try to buffer them into the Worker cache.
      if (cacheable && response.status === 200 && Number(response.headers.get("content-length")) <= 64_000_000) {
        ctx.waitUntil(caches.default.put(request, response.clone()));
      }
      return response;
    }
    const reading = request.method === "GET" || request.method === "HEAD";
    const markdown = url.pathname === "/index.md" || (url.pathname === "/" && prefersMarkdown(request.headers.get("accept")));
    if (reading && markdown) {
      const file = await env.ASSETS.fetch(new URL("/index.md", url));
      if (file.ok) {
        const headers = new Headers(file.headers);
        headers.set("content-type", "text/markdown; charset=utf-8");
        headers.set("vary", "Accept");
        // Canonical is always appea.rs, also when the workers.dev URL served it.
        headers.set("link", `<${SITE}/>; rel="canonical"`);
        return new Response(request.method === "HEAD" ? null : file.body, { headers });
      }
    }
    // The built file, fetched with the request as it came in (redirect mode
    // "manual"), so redirects, Range and conditional requests keep working.
    const response = await env.ASSETS.fetch(request);
    if (!response.headers.get("content-type")?.startsWith("text/html")) return response;
    // The page varies by Accept; say so, so no cache hands a browser the Markdown.
    const html = new Response(response.body, response);
    html.headers.append("vary", "Accept");
    return html;
  },
};
