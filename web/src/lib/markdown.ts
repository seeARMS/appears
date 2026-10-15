// Helpers for the Markdown version of the page (see negotiate.ts and src/worker.ts).

/** YAML front matter. JSON strings are valid YAML, so values need no other quoting. */
export function frontMatter(fields: Record<string, string | undefined>): string {
  const lines = Object.entries(fields).flatMap(([key, value]) => (value === undefined ? [] : [`${key}: ${JSON.stringify(value)}`]));
  return ["---", ...lines, "---"].join("\n");
}
