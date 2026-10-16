// The share card: the 1200×630 image link previews show. Drawn as SVG with
// text fitted using the fonts' real widths (metrics.ts), then rasterized by
// resvg in scripts/og.ts. Appears' light zinc palette and Inter, from
// brand/README.md: the wordmark, the headline and summary on the left, and
// the app's panel on the right, as in the page's hero mock.

import type { FontMetrics } from "./metrics";
import { orbitMarkArtwork } from "../orbit";
import { MOCK_PANEL_CONTEXT } from "../../site";

export const WIDTH = 1200;
export const HEIGHT = 630;

export interface CardFonts {
  regular: FontMetrics;
  semibold: FontMetrics;
  bold: FontMetrics;
}

export interface Result {
  kind: "photo" | "pdf" | "note" | "message";
  group: string;
  title: string;
  reason: string;
}

export interface Card {
  title: string;
  summary: string;
  footer: string;
  /** The panel's rows, from the hero mock. */
  results: readonly Result[];
}

const C = {
  background: "#FFFFFF",
  muted: "#F4F4F5",
  border: "#E4E4E7",
  mutedForeground: "#71717A",
  foreground: "#09090B",
  primary: "#18181B",
  accent: "#2563EB",
};

const PAD = 72;
const FONT = "Inter";

const f = (n: number) => Math.round(n * 10) / 10;
const esc = (s: string) => s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

/** Width at `size`, with `tracking` in em added after every character. */
function width(m: FontMetrics, text: string, size: number, tracking = 0): number {
  let w = 0;
  for (const ch of text) w += (m.advance(ch.codePointAt(0)!) ?? 0.6) + tracking;
  return w * size;
}

/** Word-wrapped to `max` wide. */
function wrap(m: FontMetrics, text: string, size: number, max: number, tracking = 0): string[] {
  const out: string[] = [];
  let line = "";
  for (const word of text.split(/\s+/).filter(Boolean)) {
    const next = line ? `${line} ${word}` : word;
    if (width(m, next, size, tracking) <= max || !line) line = next;
    else {
      out.push(line);
      line = word;
    }
  }
  if (line) out.push(line);
  return out;
}

/** Cut to fit `max`, with an ellipsis. */
function clip(m: FontMetrics, text: string, size: number, max: number): string {
  if (width(m, text, size) <= max) return text;
  let s = text;
  while (s && width(m, `${s}…`, size) > max) s = s.slice(0, -1);
  return `${s.trimEnd()}…`;
}

function mark(x: number, y: number, size: number): string {
  return `<g transform="translate(${x} ${y}) scale(${size / 48})">${orbitMarkArtwork()}</g>`;
}

function thumb(kind: Result["kind"], x: number, y: number, s: number): string {
  const clipId = `t${x}${y}`;
  const parts: string[] = [];
  if (kind === "photo") {
    parts.push(`<rect width="${s}" height="${s}" fill="#8F8984"/>`);
    parts.push(`<g transform="rotate(-6 ${s / 2} ${s / 2})"><rect x="9" y="7" width="${s - 18}" height="${s - 10}" fill="#FAFAF9"/>`);
    [0.6, 0.85, 0.5, 0.75].forEach((w, i) =>
      parts.push(`<rect x="14" y="${14 + i * 7 + (i === 3 ? 4 : 0)}" width="${f((s - 28) * w)}" height="2.5" rx="1" fill="#1E3A8A" opacity="0.75"/>`),
    );
    parts.push(`</g>`);
  } else if (kind === "pdf") {
    parts.push(`<rect width="${s}" height="${s}" fill="#E4E4E7"/><rect x="10" y="7" width="${s - 20}" height="${s}" fill="#FFFFFF"/>`);
    for (let i = 0; i < 6; i++) parts.push(`<rect x="15" y="${14 + i * 6}" width="${s - 30}" height="2" fill="#D4D4D8"/>`);
    parts.push(`<rect x="13" y="24" width="${s - 26}" height="8" fill="#FACC15" opacity="0.55"/>`);
  } else if (kind === "message") {
    parts.push(`<rect width="${s}" height="${s}" fill="${C.muted}"/>`);
    parts.push(`<path d="M12 12h22v17H22l-8 6v-6h-2z" fill="none" stroke="${C.mutedForeground}" stroke-width="2" stroke-linejoin="round"/>`);
  } else {
    parts.push(`<rect width="${s}" height="${s}" fill="#FDE68A"/><rect x="10" y="11" width="24" height="4" rx="1" fill="#78350F"/>`);
    for (let i = 0; i < 4; i++) parts.push(`<rect x="10" y="${21 + i * 7}" width="${s - 20}" height="2" fill="#B45309"/>`);
  }
  return [
    `<clipPath id="${clipId}"><rect x="${x}" y="${y}" width="${s}" height="${s}" rx="8"/></clipPath>`,
    `<g clip-path="url(#${clipId})"><g transform="translate(${x} ${y})">${parts.join("")}</g></g>`,
    `<rect x="${x + 0.5}" y="${y + 0.5}" width="${s - 1}" height="${s - 1}" rx="7.5" fill="none" stroke="#09090B" stroke-opacity="0.08"/>`,
  ].join("");
}

function panel(fonts: CardFonts, results: readonly Result[], x: number, y: number, w: number): string {
  const out: string[] = [];
  const rowH = 70;
  const head = 74;
  const groups = [...new Set(results.map((r) => r.group))];
  const h = head + groups.length * 30 + results.length * rowH + (groups.length - 1) * 9 + 14;

  // Shadow: a few soft layers, since resvg's blur filter is costly and the card is static.
  out.push(`<defs><filter id="shadow" x="-20%" y="-20%" width="140%" height="150%"><feDropShadow dx="0" dy="18" stdDeviation="22" flood-color="#09090B" flood-opacity="0.14"/></filter></defs>`);
  out.push(`<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="12" fill="${C.background}" filter="url(#shadow)"/>`);
  out.push(`<rect x="${x + 0.5}" y="${y + 0.5}" width="${w - 1}" height="${h - 1}" rx="11.5" fill="none" stroke="${C.border}"/>`);

  // Header: "Related", its source, and a "3 found" badge.
  out.push(`<text x="${x + 22}" y="${y + 36}" font-family="${FONT}" font-weight="600" font-size="19" fill="${C.foreground}">Related</text>`);
  out.push(`<text x="${x + 22}" y="${y + 58}" font-family="${FONT}" font-size="15" fill="${C.mutedForeground}">${esc(MOCK_PANEL_CONTEXT)}</text>`);
  const badge = `${results.length} found`;
  const bw = width(fonts.semibold, badge, 14) + 40;
  const bx = x + w - 20 - bw;
  out.push(`<rect x="${f(bx)}" y="${y + 22}" width="${f(bw)}" height="28" rx="14" fill="${C.background}" stroke="${C.border}"/>`);
  out.push(`<circle cx="${f(bx + 15)}" cy="${y + 36}" r="4" fill="${C.accent}"/>`);
  out.push(`<text x="${f(bx + 26)}" y="${y + 41}" font-family="${FONT}" font-weight="600" font-size="14" fill="${C.foreground}">${badge}</text>`);
  out.push(`<rect x="${x}" y="${y + head}" width="${w}" height="1" fill="${C.border}"/>`);

  let cy = y + head + 8;
  groups.forEach((g, gi) => {
    if (gi > 0) {
      out.push(`<rect x="${x + 8}" y="${cy + 2}" width="${w - 16}" height="1" fill="${C.border}"/>`);
      cy += 9;
    }
    out.push(`<text x="${x + 22}" y="${cy + 20}" font-family="${FONT}" font-weight="600" font-size="13" fill="${C.mutedForeground}">${g}</text>`);
    cy += 30;
    for (const r of results.filter((r) => r.group === g)) {
      const first = r === results[0];
      if (first) out.push(`<rect x="${x + 8}" y="${cy}" width="${w - 16}" height="${rowH - 6}" rx="8" fill="${C.muted}"/>`);
      const s = 46;
      out.push(thumb(r.kind, x + 18, cy + (rowH - 6 - s) / 2, s));
      const tx = x + 18 + s + 14;
      const tmax = w - (tx - x) - (first ? 52 : 20);
      out.push(`<text x="${tx}" y="${cy + 27}" font-family="${FONT}" font-weight="600" font-size="16" fill="${C.foreground}">${esc(clip(fonts.semibold, r.title, 16, tmax))}</text>`);
      out.push(`<text x="${tx}" y="${cy + 48}" font-family="${FONT}" font-size="14" fill="${C.mutedForeground}">${esc(clip(fonts.regular, r.reason, 14, tmax))}</text>`);
      if (first) {
        const kx = x + w - 48;
        out.push(`<rect x="${kx}" y="${cy + 20}" width="26" height="24" rx="5" fill="${C.background}" stroke="${C.border}"/>`);
        // ↩, drawn: Inter's latin subset has no arrow glyph.
        out.push(`<path d="M${kx + 18} ${cy + 27} v5 h-10 m3 -3 l-3 3 l3 3" fill="none" stroke="${C.mutedForeground}" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>`);
      }
      cy += rowH;
    }
  });
  return out.join("");
}

export function cardSvg(card: Card, fonts: CardFonts): string {
  const TRACK = -0.04;
  const max = 600;
  const SUMMARY = 26;
  const LINE = 38;

  const layout = (size: number) => {
    const lines = wrap(fonts.semibold, card.title, size, max, TRACK);
    const top = 214 + size * 0.78;
    const lead = size * 1.06;
    const summaryTop = top + (lines.length - 1) * lead + 64;
    const summary = wrap(fonts.regular, card.summary, SUMMARY, max);
    return { size, lines, top, lead, summaryTop, summary, bottom: summaryTop + (summary.length - 1) * LINE };
  };
  // The biggest headline that fits in three lines and ends above the bottom margin.
  let fit = layout(76);
  while (fit.size > 40 && (fit.lines.length > 3 || fit.bottom > HEIGHT - 70)) fit = layout(fit.size - 2);
  const { size, lines, top, lead, summaryTop } = fit;

  const headline = lines.map(
    (line, i) =>
      `<text x="${PAD}" y="${f(top + i * lead)}" font-family="${FONT}" font-weight="600" font-size="${size}" letter-spacing="${f(size * TRACK)}" fill="${C.foreground}">${esc(line)}</text>`,
  );
  const summary = fit.summary.map(
    (line, i) => `<text x="${PAD}" y="${f(summaryTop + i * LINE)}" font-family="${FONT}" font-size="${SUMMARY}" fill="${C.mutedForeground}">${esc(line)}</text>`,
  );

  return [
    `<svg xmlns="http://www.w3.org/2000/svg" width="${WIDTH}" height="${HEIGHT}" viewBox="0 0 ${WIDTH} ${HEIGHT}">`,
    `<rect width="${WIDTH}" height="${HEIGHT}" fill="${C.background}"/>`,
    // A muted desk on the right, behind the panel.
    `<rect x="740" y="0" width="${WIDTH - 740}" height="${HEIGHT}" fill="${C.muted}"/>`,
    `<rect x="740" y="0" width="1" height="${HEIGHT}" fill="${C.border}"/>`,
    // The mark and the wordmark.
    mark(PAD, 64, 44),
    `<text x="${PAD + 58}" y="98" font-family="${FONT}" font-weight="700" font-size="36" letter-spacing="${f(36 * -0.04)}" fill="${C.foreground}">appears</text>`,
    ...headline,
    ...summary,
    panel(fonts, card.results, 786, 128, 372),
    `<text x="${WIDTH - 42}" y="${HEIGHT - 40}" text-anchor="end" font-family="${FONT}" font-size="20" fill="${C.mutedForeground}">${esc(card.footer)}</text>`,
    `</svg>`,
  ].join("");
}
