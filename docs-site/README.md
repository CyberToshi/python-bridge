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
npm run build
npm run serve
```

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
