import type { APIRoute, GetStaticPaths } from "astro";
import { frontMatter } from "../../lib/markdown";
import { AUTHOR, DOWNLOAD_LABEL, DOWNLOAD_URL, GUIDES, GUIDE_TEXT, REQUIREMENTS, SITE, guidePath, type SearchGuide } from "../../site";

export const prerender = true;
export const getStaticPaths = (() => GUIDES.map((guide) => ({ params: { slug: guide.slug }, props: { guide } }))) satisfies GetStaticPaths;

export const GET: APIRoute = ({ props }) => {
  const guide = props.guide as SearchGuide;
  const markdown = [
    frontMatter({ title: guide.title, description: guide.description, url: new URL(guidePath(guide.slug), SITE).href }),
    `# ${guide.heading}`,
    ...guide.intro,
    `## ${GUIDE_TEXT.example}`,
    `Query: ${guide.example.query}`,
    `**${guide.example.source}**\n\n> ${guide.example.excerpt}`,
    guide.example.explanation,
    GUIDE_TEXT.exampleNote,
    `## ${GUIDE_TEXT.steps}`,
    guide.steps.map((step, i) => `${i + 1}. **${step.title}.** ${step.text}`).join("\n\n"),
    ...guide.sections.map((section) => `## ${section.heading}\n\n${section.paragraphs.join("\n\n")}`),
    `## ${GUIDE_TEXT.downloadHeading}`,
    GUIDE_TEXT.downloadText,
    `[${DOWNLOAD_LABEL}](${DOWNLOAD_URL}). ${REQUIREMENTS}`,
    `## ${GUIDE_TEXT.related}`,
    GUIDES.filter((other) => other.slug !== guide.slug).map((other) => `- [${other.title.split(" | ")[0]}](${new URL(guidePath(other.slug), SITE).href}): ${other.summary}`).join("\n"),
    `[Appears](${SITE}/) is made by [${AUTHOR.name}](${AUTHOR.url}).`,
  ].join("\n\n") + "\n";
  return new Response(markdown, { headers: { "content-type": "text/markdown; charset=utf-8" } });
};
