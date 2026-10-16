// The home page in Markdown, for agents: the page's copy, facts and links,
// without the header, the app mock or the footer. src/worker.ts serves it here
// and at / when a request's Accept header prefers text/markdown. The copy
// comes from src/site.ts, like the page's.

import type { APIRoute } from "astro";
import { frontMatter } from "../lib/markdown";
import {
  AUTHOR,
  DESCRIPTION,
  DOWNLOAD_LABEL,
  DOWNLOAD_URL,
  FAQ,
  FAQ_HEADING,
  GET_HEADING,
  GET_TEXT,
  GLYPHS,
  HEADLINE,
  HOW,
  HOW_HEADING,
  LEDE,
  LICENSE,
  LICENSE_URL,
  MOCK_CAPTION,
  MOCK_NOTE,
  MOCK_RESULTS,
  NAME,
  PRIVACY,
  PRIVACY_HEADING,
  PRIVACY_TEXT,
  QUIET,
  QUIET_HEADING,
  REQUIREMENTS,
  SITE,
  TITLE,
} from "../site";

export const prerender = true;

const DOWNLOAD = `[${DOWNLOAD_LABEL}](${new URL(DOWNLOAD_URL, SITE).href}). ${REQUIREMENTS}`;

const MARKDOWN = `${[
  frontMatter({ title: TITLE, description: DESCRIPTION, url: `${SITE}/` }),
  `# ${HEADLINE}`,
  LEDE,
  DOWNLOAD,
  `${MOCK_CAPTION} The panel shows (${MOCK_NOTE.toLowerCase().replace(/\.$/, "")}):`,
  MOCK_RESULTS.map((r) => `- **${r.title}:** ${r.reason}`).join("\n"),
  `## ${HOW_HEADING}`,
  ...HOW.map((item) => `### ${item.title}\n\n${item.text}`),
  `## ${QUIET_HEADING}`,
  QUIET,
  `The ring in the menu bar has ${GLYPHS.length} states: ${GLYPHS.map((g) => g.label.toLowerCase()).join(", ")}.`,
  `## ${PRIVACY_HEADING}`,
  PRIVACY_TEXT,
  PRIVACY.map((row) => `- **${row.label}:** ${row.text}`).join("\n"),
  `## ${FAQ_HEADING}`,
  ...FAQ.map((item) => `### ${item.q}\n\n${item.a.join("\n\n")}`),
  `## ${GET_HEADING}`,
  GET_TEXT,
  DOWNLOAD,
  "## Links",
  [`- [${LICENSE} license](${LICENSE_URL})`, `- [llms.txt](${SITE}/llms.txt): ${NAME} in brief, for agents`].join("\n"),
  `${NAME} is made by [${AUTHOR.name}](${AUTHOR.url}).`,
].join("\n\n")}\n`;

export const GET: APIRoute = () => new Response(MARKDOWN, { headers: { "content-type": "text/markdown; charset=utf-8" } });
