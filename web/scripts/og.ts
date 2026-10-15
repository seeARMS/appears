// Renders the site's share card to public/og.png, from the headline, the card
// copy and the mock's results in src/site.ts. Re-run it after changing any of them:
//
//   npm run og

import { readFileSync, writeFileSync } from "node:fs";
import { initWasm, Resvg } from "@resvg/resvg-wasm";
import { cardSvg } from "../src/lib/og/card";
import { readMetrics } from "../src/lib/og/metrics";
import { CARD, HEADLINE, MOCK_RESULTS } from "../src/site";

// Inter (SIL Open Font License, see src/lib/og/fonts/OFL.txt).
const FONTS = ["Inter-Regular", "Inter-SemiBold", "Inter-Bold"];
const buffers = FONTS.map((name) => new Uint8Array(readFileSync(`src/lib/og/fonts/${name}.ttf`)));
const [regular, semibold, bold] = buffers.map(readMetrics);

await initWasm(readFileSync("node_modules/@resvg/resvg-wasm/index_bg.wasm"));

const out = "public/og.png";
const svg = cardSvg({ title: HEADLINE, summary: CARD.summary, footer: CARD.footer, results: MOCK_RESULTS }, { regular, semibold, bold });
const png = new Resvg(svg, { font: { fontBuffers: buffers, defaultFontFamily: "Inter" } }).render().asPng();
writeFileSync(out, png);
console.log(`${out}: ${(png.length / 1024).toFixed(0)} KB`);
