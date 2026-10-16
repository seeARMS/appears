// llms.txt (llmstxt.org, v2): what Appears is, in brief, for agents, with a
// link to the Markdown version of the home page. Prerendered to a static
// file; public/_headers gives it its charset.

import type { APIRoute } from "astro";
import { AUTHOR, DOWNLOAD_URL, HARDWARE, LEDE, LICENSE, LICENSE_URL, OPERATING_SYSTEM, PRIVACY, QUIET, SITE, SOURCE_LABEL, SOURCE_URL, SUMMARY } from "../site";

export const prerender = true;

const LLMS = `${[
  "# Appears",
  `> ${SUMMARY}`,
  LEDE,
  "It reads the window in front of you through the macOS Accessibility API, only when something changes, keeps that text in memory and throws it away. It indexes documents, PDFs, images and screenshots in the home folder, plus Apple Notes, Messages and their locally downloaded photos when access is granted. Google's EmbeddingGemma 2 runs on the Mac alongside full-text search. Suggestions favour information you haven't opened in a while. It shows at most three suggestions, each with a one-line reason; you can open one, Quick Look it, or drag it into what you're writing. A separate search window lets you describe what you remember and search all enabled sources, including recent items.",
  QUIET,
  ["How it keeps everything on the Mac:", "", ...PRIVACY.map((row) => `- ${row.label}: ${row.text}`)].join("\n"),
  "In detail: reading files, running the model and holding the index happen in a separate engine process inside the App Sandbox with no network entitlement. The menu bar app, which reads the screen through the Accessibility API and so can't be sandboxed, contains no networking code, and a build check fails if it ever imports a networking API. The only log is which suggestions were opened or dismissed, without the text of what was on screen.",
  ["Requirements:", "", `- A ${HARDWARE}`, `- ${OPERATING_SYSTEM}`].join("\n"),
  `It's free and open source under the ${LICENSE} license (${LICENSE_URL}). Download: ${new URL(DOWNLOAD_URL, SITE).href}`,
  `Appears is made by ${AUTHOR.name} (${AUTHOR.url}), the founder and CEO of Paragraph.`,
  `This page has a Markdown version at ${SITE}/index.md, and ${SITE}/ returns Markdown when a request's Accept header prefers text/markdown.`,
  "## Docs",
  `- [Appears](${SITE}/index.md): what Appears does, how it decides what to show, and how it keeps everything on your Mac`,
  "## Optional",
  `- [${SOURCE_LABEL}](${SOURCE_URL}): source code for Appears`,
  `- [${AUTHOR.name}](${AUTHOR.url}): who made Appears`,
].join("\n\n")}\n`;

export const GET: APIRoute = () => new Response(LLMS, { headers: { "content-type": "text/plain; charset=utf-8" } });
