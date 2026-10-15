# appea.rs

The landing site for Appears, the open-source Mac menu bar app that notices what you're working on and quietly shows related files you already have. It will live at [appea.rs](https://appea.rs). Made by [Colin Armstrong](https://armstr.ng).

Astro 7, built to plain static files, behind a small hand-written Cloudflare Worker. One page with its CSS inlined, a Markdown version for agents, `llms.txt`, and the app's (empty, for now) update feed. No analytics or third-party scripts of any kind, and no client JavaScript.

Follows the conventions in Colin's root `AGENTS.md` (Markdown versions, `llms.txt`, structured data, shared `@id`s).

## What's where

| What | Where |
| --- | --- |
| All the copy: headline, sections, privacy rows, the mock's results, the share card's text | `src/site.ts` (the page, its Markdown, `llms.txt` and the share card all read it) |
| The page and its JSON-LD | `src/pages/index.astro`, `src/layouts/Base.astro` |
| Palette, type and layout | `src/styles/global.css` (colours from `../brand/README.md`); fonts are set in `astro.config.mjs` |
| The hero mock (Mail reply + Appears panel), in HTML and CSS | `src/components/Mock.astro`. Everything in it is made up. |
| Mark and menu bar glyph | `src/components/Mark.astro`, `src/components/Glyph.astro`; favicon `public/favicon.svg` |
| Markdown for agents | `src/pages/index.md.ts` → `/index.md`; `src/worker.ts` also serves it at `/` when the Accept header prefers `text/markdown` (`src/lib/negotiate.ts`) |
| `llms.txt` | `src/pages/llms.txt.ts` |
| Sparkle update feed | `public/appcast.xml` (no items yet; `public/_headers` gives it a 5-minute cache) |
| Share card | `public/og.png`, drawn by `scripts/og.ts` and `src/lib/og/` |
| Headers, robots, sitemap | `public/_headers`, `public/robots.txt`, `public/sitemap.xml` (just `/`) |
| www.appea.rs → appea.rs | `redirect/` |

The config says `output: "static"`, with no Cloudflare adapter. `wrangler.jsonc` points `main` at `src/worker.ts` and serves `dist/` as static assets. Only `/` and `/index.md` go through the Worker (`assets.run_worker_first`); everything else is served straight from the files. For `/`, the Worker fetches the built file with the original request, so redirects and conditional requests keep working, and adds `Accept` to `Vary`.

## Develop

```sh
npm install
npm run dev          # astro dev; from the repo root, the "web" config in .claude/launch.json runs it on port 4341
npm run check        # type-check
npm run build        # dist/
npm run og           # re-render public/og.png after changing HEADLINE or CARD in src/site.ts
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

Fonts are [Instrument Serif](https://github.com/Instrument/instrument-serif) and [Hanken Grotesk](https://github.com/marcologous/hanken-grotesk), both under the SIL Open Font License, loaded through Astro's fonts API from Fontsource. The share card's copies are in `src/lib/og/fonts/`.
