// The Worker in front of the static site. It only sees the paths in
// wrangler.jsonc's assets.run_worker_first ("/" and "/index.md"); every other
// file is served straight from dist/.
//
// The page has a Markdown version built beside it (/index.md). It's served at
// that address, and at / when the request's Accept header prefers
// text/markdown (src/lib/negotiate.ts). Browsers never ask for Markdown, so
// they always get the HTML.

import { prefersMarkdown } from "./lib/negotiate";
import { SITE } from "./site";

interface Env {
  ASSETS: { fetch: (input: Request | URL | string, init?: RequestInit) => Promise<Response> };
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
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
