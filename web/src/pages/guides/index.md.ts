import type { APIRoute } from "astro";
import { frontMatter } from "../../lib/markdown";
import { GUIDES, GUIDES_INDEX, SITE, guidePath } from "../../site";

export const prerender = true;
const markdown = [
  frontMatter({ title: GUIDES_INDEX.title, description: GUIDES_INDEX.description, url: new URL(GUIDES_INDEX.path, SITE).href }),
  `# ${GUIDES_INDEX.heading}`,
  GUIDES_INDEX.eyebrow,
  GUIDES_INDEX.intro,
  ...GUIDES.map((guide) => [
    `## [${guide.title.split(" | ")[0]}](${new URL(guidePath(guide.slug), SITE).href})`,
    guide.summary,
    `${GUIDES_INDEX.example}: ${guide.example.query}`,
    `**${guide.example.source}**\n\n> ${guide.example.excerpt}`,
  ].join("\n\n")),
  GUIDES_INDEX.exampleNote,
].join("\n\n") + "\n";

export const GET: APIRoute = () => new Response(markdown, { headers: { "content-type": "text/markdown; charset=utf-8" } });
