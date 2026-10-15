// The share card: the 1200×630 image link previews show. Drawn as SVG with
// text fitted using the fonts' real widths (metrics.ts), then rasterized by
// resvg in scripts/og.ts. Appears' light palette, from brand/README.md.

import type { FontMetrics } from "./metrics";

export const WIDTH = 1200;
export const HEIGHT = 630;

export interface CardFonts {
  serif: FontMetrics;
  italic: FontMetrics;
  regular: FontMetrics;
}

export interface Card {
  /** The headline: its first clause is set roman, the rest italic, and its full stop in the signal colour. */
  title: string;
  summary: string;
  footer: string;
}

const C = {
  paper: "#F4F1EA",
  ink: "#17150F",
  soft: "#3A362E",
  muted: "#6B655A",
  rule: "#DCD6CA",
  signal: "#E0531F",
};

const PAD = 80;
const SERIF = "Instrument Serif";
const SANS = "Hanken Grotesk";

const f = (n: number) => Math.round(n * 10) / 10;
const esc = (s: string) => s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

function width(m: FontMetrics, text: string, size: number): number {
  let w = 0;
  for (const ch of text) w += m.advance(ch.codePointAt(0)!) ?? 0.5;
  return w * size;
}

/** Word-wrapped to `max` wide. */
function wrap(m: FontMetrics, text: string, size: number, max: number): string[] {
  const out: string[] = [];
  let line = "";
  for (const word of text.split(/\s+/).filter(Boolean)) {
    const next = line ? `${line} ${word}` : word;
    if (width(m, next, size) <= max || !line) line = next;
    else {
      out.push(line);
      line = word;
    }
  }
  if (line) out.push(line);
  return out;
}

export function cardSvg(card: Card, fonts: CardFonts): string {
  const [roman, italic = ""] = card.title.replace(/\.$/, "").split(/,\s*/, 2);
  const max = WIDTH - PAD * 2 - 140;

  const SUMMARY = 28;
  const layout = (size: number) => {
    const italicLines = wrap(fonts.italic, `${italic}.`, size, max);
    const top = 168 + size * 0.8;
    const summaryTop = top + italicLines.length * size + 64;
    const summary = wrap(fonts.regular, card.summary, SUMMARY, 820);
    return { size, italicLines, top, summaryTop, summary, bottom: summaryTop + (summary.length - 1) * 40 };
  };
  // The biggest size at which the roman clause fits one line and everything ends above the bottom margin.
  let fit = layout(96);
  while (fit.size > 48 && (width(fonts.serif, `${roman},`, fit.size) > max || fit.italicLines.length > 2 || fit.bottom > HEIGHT - 64))
    fit = layout(fit.size - 2);
  const { size, italicLines, top, summaryTop } = fit;

  const lines = [
    `<text x="${PAD}" y="${f(top)}" font-family="${SERIF}" font-size="${size}" fill="${C.ink}">${esc(roman)},</text>`,
    ...italicLines.map((line, i) => {
      const last = i === italicLines.length - 1;
      const body = last ? line.replace(/\.$/, "") : line;
      const stop = last ? `<tspan fill="${C.signal}">.</tspan>` : "";
      return `<text x="${PAD}" y="${f(top + (i + 1) * size)}" font-family="${SERIF}" font-style="italic" font-size="${size}" fill="${C.soft}">${esc(body)}${stop}</text>`;
    }),
  ];
  const summary = fit.summary.map(
    (line, i) => `<text x="${PAD}" y="${f(summaryTop + i * 40)}" font-family="${SANS}" font-size="${SUMMARY}" fill="${C.muted}">${esc(line)}</text>`,
  );

  // The mark, large, half off the right edge: something surfacing at the top of a field of view.
  const ring = { cx: 1090, cy: 420, r: 230 };

  return [
    `<svg xmlns="http://www.w3.org/2000/svg" width="${WIDTH}" height="${HEIGHT}" viewBox="0 0 ${WIDTH} ${HEIGHT}">`,
    `<rect width="${WIDTH}" height="${HEIGHT}" fill="${C.paper}"/>`,
    `<circle cx="${ring.cx}" cy="${ring.cy}" r="${ring.r}" fill="none" stroke="${C.rule}" stroke-width="44"/>`,
    `<circle cx="${ring.cx}" cy="${ring.cy - ring.r}" r="58" fill="${C.signal}"/>`,
    // The small mark and the name.
    `<g transform="translate(${PAD} 64) scale(${44 / 64})"><circle cx="32" cy="34" r="22" fill="none" stroke="${C.ink}" stroke-width="5"/><circle cx="32" cy="17" r="8" fill="${C.signal}"/></g>`,
    `<text x="${PAD + 56}" y="100" font-family="${SERIF}" font-size="44" fill="${C.ink}">Appears</text>`,
    ...lines,
    ...summary,
    `<text x="${WIDTH - PAD}" y="98" text-anchor="end" font-family="${SANS}" font-size="24" fill="${C.muted}">${esc(card.footer)}</text>`,
    `</svg>`,
  ].join("");
}
