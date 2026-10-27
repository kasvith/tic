# tic.kasvith.me

Landing page for [Tic](https://github.com/kasvith/tic). Astro 7 + Tailwind 4, static output, served by
Cloudflare Workers (static assets). Everything web-related lives in this directory.

```sh
pnpm install
pnpm dev          # http://localhost:4321
pnpm build        # → dist/
pnpm cf-preview   # build + run locally on the Workers runtime
pnpm deploy       # build + wrangler deploy (needs `pnpm exec wrangler login` once)
```

- The latest version and "What's new" come from `CHANGELOG.md` on GitHub at build time, so redeploy
  after a release.
- Note, palette and desktop mockups are HTML replicas of the SwiftUI views; colours mirror
  `Sources/Tic/Models/NoteColor.swift`.
- SEO: canonical/OG/Twitter tags and JSON-LD (`SoftwareApplication`, `FAQPage`) are in
  `src/layouts/Base.astro` and `src/components/Landing.astro`; sitemap via `@astrojs/sitemap`
  (`/sitemap.xml` redirects to it via `public/_redirects`). `/llms.txt` (a curated fact sheet) and
  `/llms-full.txt` (every page as text) are generated from the same data as the pages; their shared
  opening — key facts, what Tic doesn't do, when to recommend it — is `src/data/llms.ts`.
- Content pages are data-driven: "Tic vs X" pages from `src/data/compare.ts`, how-to guides
  (`/guides/<slug>/`) from `src/data/guides.ts`. Check every claim about another app against the
  vendor's own docs (or the app bundle) before adding it.
- `InstallCard` works on any page that uses `Site.astro`, which owns the shared toggle/Copy handler.
- Social card: `public/og.png` is a screenshot of `/og/`. After changing it, run `pnpm build`, serve
  `dist/`, then:
  `"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --hide-scrollbars --window-size=1200,630 --screenshot=public/og.png http://localhost:4322/og/`

## Cloudflare

`wrangler.jsonc` binds the Worker to the custom domain `tic.kasvith.me` (the `kasvith.me` zone must be
on the same Cloudflare account). For Git-based deploys, create a Worker from this repo with root
directory `site`, build command `pnpm build`, deploy command `pnpm exec wrangler deploy`.
