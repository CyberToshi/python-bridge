# Python Bridge Documentation Site

This directory contains the Docusaurus website for the Godot Python Bridge addon.
It is intentionally separate from the runtime addon and from the existing
repository documentation in `../docs/`.

## Requirements

- Node.js 20 or newer
- npm, or another compatible package manager

## Install dependencies

From this directory:

```bash
npm install
```

## Run locally

```bash
npm start
```

Docusaurus opens a local development server, normally at
`http://localhost:3000`.

## Build the site

```bash
npm run build     # exportiert zuerst das Druck-HTML, dann der Docusaurus-Build
npm run serve
```

## Printable HTML / PDF export

The whole documentation can be exported as a single, print-optimized document
(table of contents, page breaks, all chapters in one file):

```bash
npm run export:docs        # HTML + PDF (PDF requires LibreOffice/soffice)
npm run export:docs:html   # HTML only
```

The result is written to `static/PythonBridge_Dokumentation.html` and
`static/PythonBridge_Dokumentation.pdf` and served at
`/python-bridge/PythonBridge_Dokumentation.*`. `npm run build` regenerates the
HTML on every build so it never goes stale; the PDF is a committed snapshot
the maintainer regenerates with `npm run export:docs` when the docs change
substantially.

## Configure GitHub

The site is published to GitHub Pages as a project page:

- `url`: `https://cybertoshi.github.io`
- `baseUrl`: `/python-bridge/`
- `organizationName`: `CyberToshi`
- `projectName`: `python-bridge`

Deployment happens automatically via GitHub Actions (see
`.github/workflows/deploy-docs.yml` in the repository root). The built site
is served at `https://cybertoshi.github.io/python-bridge/`.

## Documentation source

- `docs/intro.md`: welcome page and feature overview
- `docs/installation.md`: Godot installation workflow
- `docs/getting-started.md`: first working example
- `docs/api.md`: initial API overview
- `sidebars.js`: left navigation order
