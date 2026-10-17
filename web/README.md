# appea.rs

The landing site for Appears, the open-source Mac menu bar app that notices what you're working on and quietly shows related files you already have. It lives at [appea.rs](https://appea.rs). Made by [Colin Armstrong](https://armstr.ng).

Astro 7, built to plain static files, behind a small hand-written Cloudflare Worker. The home page and three search guides have inlined CSS and Markdown versions for agents, alongside `llms.txt` and the app's signed update feed served from R2. No analytics or third-party scripts are included in the source. Small first-party scripts run the home page's demo and scroll reveals; the guides need no client JavaScript.

Follows the site conventions in the repo's [AGENTS.md](../AGENTS.md#site-conventions) (Markdown versions, `llms.txt`, one source for copy).

## What's where

| What | Where |
| --- | --- |
| All the copy: headline, sections, privacy rows, the mock's results, the share card's text | `src/site.ts` (the page, its Markdown, `llms.txt` and the share card all read it) |
| The page and its JSON-LD | `src/pages/index.astro`, `src/layouts/Base.astro` |
| Source setup and search guides | `src/pages/guides/[slug].astro`, with copy and route names in `src/site.ts`; `[slug].md.ts` builds matching Markdown |
| The actual app's light/dark demo screenshot | `src/components/AppScreenshot.astro`; Astro generates responsive WebP images from `../docs/screenshots/` |
| Palette, type and layout | `src/styles/global.css` (shadcn zinc tokens from `../brand/README.md`); fonts are set in `astro.config.mjs` |
| The hero mock (Mail reply + Appears panel), in HTML and CSS | `src/components/Mock.astro`. Everything in it is made up. |
| Orbit mark and five menu bar states | `src/lib/orbit.ts`, `src/components/Mark.astro`, `src/components/Glyph.astro`; `scripts/brand.ts` generates the SVGs, favicon and Mac icon sizes |
| Markdown for agents | `src/pages/index.md.ts` → `/index.md`; `src/worker.ts` also serves it at `/` when the Accept header prefers `text/markdown` (`src/lib/negotiate.ts`) |
| `llms.txt` | `src/pages/llms.txt.ts` |
| Sparkle update feed | `/appcast.xml` serves the signed R2 object unchanged, with a 5-minute cache; release notes come from the matching GitHub release |
| Latest app, versioned downloads and model files | `src/lib/download.ts`, `src/worker.ts`, private `DOWNLOADS` R2 binding in `wrangler.jsonc`; `/app.dmg` redirects to the latest immutable version |
| Share card | `public/og.png`, drawn by `scripts/og.ts` and `src/lib/og/` |
| Headers, robots, sitemap | `public/_headers`, `public/robots.txt`, `src/pages/sitemap.xml.ts` (home page and guides, generated from shared routes) |
| www.appea.rs → appea.rs | `redirect/` |

The config says `output: "static"`, with no Cloudflare adapter. `wrangler.jsonc` points `main` at `src/worker.ts` and serves `dist/` as static assets. `/`, `/index.md`, `/guides/*`, `/app.dmg`, `/appcast.xml`, `/downloads/*` and `/models/*` go through the Worker (`assets.run_worker_first`); other assets are served straight from the files. HTML and Markdown requests preserve methods, conditional headers and status codes. Page responses vary by `Accept`; every Markdown response points to its own HTML canonical. The sitemap lists HTML pages only.

The R2 bucket stays private. `/app.dmg` reads `latest.json` and returns a `no-store` redirect to a versioned DMG. Versioned downloads support GET, HEAD, ETags and single byte ranges for resuming. The Worker caches small versioned app downloads (up to 64 MB) through the Cache API; model files stream without buffering into the cache. The release workflow uploads and verifies the separately hosted model before making the new app the latest. See the root README for setup and credentials. Don't deploy the download CTA before the first signed app and model files are ready.

## Develop

Use Node 24 (Astro requires at least 22.22.0). Keep TypeScript on 6.x until
`@astrojs/check` supports TypeScript 7; its current peer dependency accepts only
TypeScript 5 or 6. Miniflare follows the version used by Wrangler, including its
current 5.x beta.

```sh
npm install
npm run dev          # astro dev; from the repo root, the "web" config in .claude/launch.json runs it on port 4341
npm run check        # type-check
npm test             # real local Worker/R2 integration: redirects, ranges, caching headers and model routes
npm run build        # dist/
npm run brand        # regenerate Orbit's SVGs, favicon and all Mac app icon sizes
npm run og           # re-render public/og.png after changing HEADLINE, CARD or MOCK_RESULTS in src/site.ts
```

To try the built Worker, Markdown negotiation included:

```sh
npm run build && npm run cf -- dev --local
curl -H "Accept: text/markdown, text/html, */*" localhost:8787/
```

`wrangler dev` may rewrite `https://appea.rs` to `localhost` in response headers such as the Markdown's canonical `Link`; add `--local-upstream upstream.test` to see them as production sends them.

## Deploy

Not deployed yet. Deploys go to the **personal** Cloudflare account. Wrangler credentials for it live in a separate profile (`~/.config/wrangler-personal`), so a work login in the default profile is never used. `account_id` in `wrangler.jsonc` pins the account as a second guard.

```sh
npm run cf:login     # once: authorize the personal account
npm run deploy       # the site (appea.rs + workers.dev)
npm run deploy:www   # the Worker that redirects www.appea.rs to appea.rs
npm run cf -- tail   # any other wrangler command, same profile
```

Workers Builds isn't connected yet. Once it is, pushing to `main` deploys the site: set its root directory to `web`, the build command to `npm run build` and the deploy command to `npx wrangler deploy`. The www redirect isn't part of that; deploy it by hand when it changes.

## Attribution

The font is [Inter](https://github.com/rsms/inter), under the SIL Open Font License, loaded through Astro's fonts API from Fontsource. The share card's copies are in `src/lib/og/fonts/`.
