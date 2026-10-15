// Renders the site's share card to public/og.png, from the headline and the
// card copy in src/site.ts. Re-run it after changing either:
//
//   npm run og

import { readFileSync, writeFileSync } from "node:fs";
import { initWasm, Resvg } from "@resvg/resvg-wasm";
import { cardSvg } from "../src/lib/og/card";
import { readMetrics } from "../src/lib/og/metrics";
import { CARD, HEADLINE } from "../src/site";

// Instrument Serif and Hanken Grotesk (SIL Open Font License, see src/lib/og/fonts/OFL.txt).
const FONTS = ["InstrumentSerif-Regular", "InstrumentSerif-Italic", "HankenGrotesk-Regular"];
const buffers = FONTS.map((name) => new Uint8Array(readFileSync(`src/lib/og/fonts/${name}.ttf`)));
const [serif, italic, regular] = buffers.map(readMetrics);

await initWasm(readFileSync("node_modules/@resvg/resvg-wasm/index_bg.wasm"));

const out = "public/og.png";
const svg = cardSvg({ title: HEADLINE, summary: CARD.summary, footer: CARD.footer }, { serif, italic, regular });
const png = new Resvg(svg, { font: { fontBuffers: buffers, defaultFontFamily: "Hanken Grotesk" } }).render().asPng();
writeFileSync(out, png);
console.log(`${out}: ${(png.length / 1024).toFixed(0)} KB`);
