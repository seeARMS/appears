// The copy in src/site.ts uses two bits of Markdown, `code` and
// [links](https://…), so the Markdown version can use it as it is. This turns
// them into HTML for the page. Only for the site's own copy: it trusts the URLs.
//
// Keyboard shortcuts are written in braces with their keys' names, like
// {Control–Shift–Space} or {Return}. The page draws them as keycaps; the
// Markdown version runs its text through plainKeys(), which drops the braces.

const escape = (s: string) => s.replace(/[&<>"]/g, (c) => `&#${c.charCodeAt(0)};`);

const SHORTCUT = /\{([A-Z][A-Za-z0-9]*(?:–[A-Za-z0-9]+)*)\}/g;

/** How the Mac draws each modifier and special key. Anything else is drawn as its name. */
const SYMBOLS: Record<string, string> = {
  Control: "⌃",
  Option: "⌥",
  Shift: "⇧",
  Command: "⌘",
  Return: "↩",
  Delete: "⌫",
};

function keycaps(shortcut: string): string {
  const caps = shortcut
    .split("–")
    .map((key) => {
      const symbol = SYMBOLS[key];
      return symbol
        ? `<kbd class="keycap keycap-symbol" title="${key}" aria-hidden="true">${symbol}</kbd>`
        : `<kbd class="keycap" aria-hidden="true">${key}</kbd>`;
    })
    .join("");
  return `<kbd class="keys">${caps}<span class="sr-only">${shortcut}</span></kbd>`;
}

export function inline(text: string): string {
  return escape(text)
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, '<a href="$2">$1</a>')
    .replace(SHORTCUT, (_, shortcut: string) => keycaps(shortcut));
}

/** For the Markdown versions: {Control–Shift–Space} becomes Control–Shift–Space. */
export const plainKeys = (text: string) => text.replace(SHORTCUT, "$1");
