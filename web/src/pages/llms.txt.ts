// llms.txt (llmstxt.org, v2): what Appears is, in brief, for agents, with a
// link to the Markdown version of the home page. Prerendered to a static
// file; public/_headers gives it its charset.

import type { APIRoute } from "astro";
import { AUTHOR, HARDWARE, LEDE, LICENSE, LICENSE_URL, OPERATING_SYSTEM, PRIVACY, QUIET, SITE, SUMMARY } from "../site";

export const prerender = true;

const LLMS = `${[
  "# Appears",
  `> ${SUMMARY}`,
  LEDE,
  "It reads the window in front of you through the macOS Accessibility API, only when something changes, keeps that text in memory and throws it away. It indexes files in the home folder and Apple Notes with Google's EmbeddingGemma 2, running on the Mac, plus full-text search, and ranks for what you haven't opened in a long time, not only for what's similar. It shows at most three things, each with a one-line reason; you can open one, Quick Look it, or drag it into what you're writing.",
  QUIET,
  ["How it keeps everything on the Mac:", "", ...PRIVACY.map((row) => `- ${row.label}: ${row.text}`)].join("\n"),
  ["Requirements:", "", `- A ${HARDWARE}`, `- ${OPERATING_SYSTEM}`].join("\n"),
  `Status: in private testing. There's no download yet. It's free and open source under the ${LICENSE} license (${LICENSE_URL}).`,
  `Appears is made by ${AUTHOR.name} (${AUTHOR.url}), the founder and CEO of Paragraph.`,
  `This page has a Markdown version at ${SITE}/index.md, and ${SITE}/ returns Markdown when a request's Accept header prefers text/markdown.`,
  "## Docs",
  `- [Appears](${SITE}/index.md): what Appears does, how it decides what to show, and how it keeps everything on your Mac`,
  "## Optional",
  `- [${AUTHOR.name}](${AUTHOR.url}): who made Appears`,
].join("\n\n")}\n`;

export const GET: APIRoute = () => new Response(LLMS, { headers: { "content-type": "text/plain; charset=utf-8" } });
