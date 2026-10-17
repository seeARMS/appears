import type { APIRoute } from "astro";
import { GUIDES, SITE, guidePath } from "../site";

export const prerender = true;
const urls = ["/", ...GUIDES.map((guide) => guidePath(guide.slug))];
export const GET: APIRoute = () => new Response(
  `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls.map((path) => `  <url><loc>${new URL(path, SITE).href}</loc></url>`).join("\n")}\n</urlset>\n`,
  { headers: { "content-type": "application/xml; charset=utf-8" } },
);
