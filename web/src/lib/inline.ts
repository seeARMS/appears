// The copy in src/site.ts uses two bits of Markdown, `code` and
// [links](https://…), so the Markdown version can use it as it is. This turns
// them into HTML for the page. Only for the site's own copy: it trusts the URLs.

const escape = (s: string) => s.replace(/[&<>"]/g, (c) => `&#${c.charCodeAt(0)};`);

export function inline(text: string): string {
  return escape(text)
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, '<a href="$2">$1</a>');
}
