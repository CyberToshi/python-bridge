// Builds a single, print-optimized HTML document from the Docusaurus docs
// sources, so the whole documentation can be read offline or saved as a PDF
// from the browser. When LibreOffice is available the script additionally
// renders a PDF next to the HTML.
//
// Usage:
//   node scripts/export-docs.mjs          # HTML + PDF (if LibreOffice exists)
//   node scripts/export-docs.mjs --no-pdf # HTML only
//
// Output goes to docs-site/static/, which Docusaurus copies into the build
// (served as /python-bridge/PythonBridge_Dokumentation.html|pdf).

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync, execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { marked } from 'marked';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const siteDir = path.resolve(__dirname, '..');           // docs-site/
const repoRoot = path.resolve(siteDir, '..');            // repository root
const docsDir = path.join(siteDir, 'docs');
const staticDir = path.join(siteDir, 'static');
const outBase = 'PythonBridge_Dokumentation';
const outHtml = path.join(staticDir, `${outBase}.html`);
const outPdf = path.join(staticDir, `${outBase}.pdf`);
const wantPdf = !process.argv.includes('--no-pdf');

const SITE_URL = 'https://cybertoshi.github.io/python-bridge';
const require = createRequire(import.meta.url);

marked.setOptions({ gfm: true, breaks: false });

// --------------------------------------------------------------------- order
function flattenSidebar(items, out = []) {
  for (const item of items) {
    if (typeof item === 'string') out.push(item);
    else if (item && item.type === 'category') flattenSidebar(item.items, out);
  }
  return out;
}

function docOrder() {
  const sidebarsPath = path.join(siteDir, 'sidebars.js');
  const sidebars = require(sidebarsPath);
  return flattenSidebar(sidebars.tutorialSidebar);
}

// ---------------------------------------------------------------- markdown
function parseFrontMatter(source) {
  const match = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?/.exec(source);
  if (!match) return { title: '', body: source };
  const titleMatch = /^title:\s*(.+?)\s*$/m.exec(match[1]);
  const title = titleMatch ? titleMatch[1].replace(/^["']|["']$/g, '') : '';
  return { title, body: source.slice(match[0].length) };
}

function firstHeading(body) {
  const match = /^#\s+(.+?)\s*$/m.exec(body);
  return match ? match[1] : '';
}

function escapeHtml(text) {
  return text
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

// Render markdown, translating Docusaurus admonitions (:::note … :::) into
// plain styled divs. Nested admonitions are not used in these docs.
function renderMarkdown(md) {
  const lines = md.split('\n');
  const blocks = [];
  let buffer = [];
  let i = 0;

  const flush = () => {
    if (buffer.length) {
      blocks.push(marked.parse(buffer.join('\n')));
      buffer = [];
    }
  };

  while (i < lines.length) {
    const open = /^:::(note|tip|info|warning|danger|caution)\s*(.*)$/.exec(lines[i]);
    if (open) {
      flush();
      const kind = open[1];
      const titleText = open[2].trim();
      const inner = [];
      i += 1;
      while (i < lines.length && !/^:::\s*$/.test(lines[i])) {
        inner.push(lines[i]);
        i += 1;
      }
      i += 1; // closing :::
      const innerHtml = marked.parse(inner.join('\n'));
      const heading = titleText ? `<p class="adm-title">${escapeHtml(titleText)}</p>` : '';
      blocks.push(`<div class="adm adm-${kind}">${heading}${innerHtml}</div>`);
      continue;
    }
    buffer.push(lines[i]);
    i += 1;
  }
  flush();
  return blocks.join('\n');
}

function rewriteLinks(html) {
  return html
    .replace(/href="\.\/([^"#]*)(#[^"]*)?"/g, (_m, id, hash = '') => {
      const target = id === '' ? '' : `/docs/${id}`;
      return `href="${SITE_URL}${target}${hash || ''}"`;
    })
    .replace(/href="\/docs\//g, `href="${SITE_URL}/docs/`)
    .replace(/src="\/img\//g, 'src="img/')
    .replace(/src="\/python-bridge\//g, 'src="');
}

// ------------------------------------------------------------------- render
const chapters = [];
for (const id of docOrder()) {
  const file = path.join(docsDir, `${id}.md`);
  if (!fs.existsSync(file)) {
    console.warn(`[export] warnung: ${file} fehlt, übersprungen`);
    continue;
  }
  const { title, body } = parseFrontMatter(fs.readFileSync(file, 'utf8'));
  chapters.push({
    id,
    title: title || firstHeading(body) || id,
    html: rewriteLinks(renderMarkdown(body)),
  });
}

// Repository guides are part of the documentation bundle; include the hands-on
// guide as an appendix so the printed document is self-contained.
const appendixFile = path.join(repoRoot, 'docs', 'HANDS_ON_CONNECT_GUIDE.md');
if (fs.existsSync(appendixFile)) {
  const body = fs.readFileSync(appendixFile, 'utf8');
  chapters.push({
    id: 'hands-on',
    title: 'Anhang: HANDS-ON-Connect-Guide',
    html: rewriteLinks(renderMarkdown(body)),
  });
}

const toc = chapters
  .map((c) => `<li><a href="#${c.id}">${escapeHtml(c.title)}</a></li>`)
  .join('\n');

const sections = chapters
  .map((c) => `<section id="${c.id}" class="chapter">\n${c.html}\n</section>`)
  .join('\n');

const generated = new Date().toISOString().slice(0, 10);

const css = `
  :root { --line: #c8c8c8; --muted: #555; }
  * { box-sizing: border-box; }
  body {
    font-family: "Liberation Serif", Georgia, "Times New Roman", serif;
    font-size: 10pt; line-height: 1.35; color: #111; background: #fff;
    max-width: 900px; margin: 0 auto; padding: 28px 26px 56px;
  }
  .cover { text-align: center; border-bottom: 2px solid #111; padding-bottom: 14px; margin-bottom: 18px; }
  .cover h1 { font-size: 26pt; margin: 0 0 4px; }
  .cover .subtitle { font-size: 12pt; color: #222; margin: 0 0 8px; }
  .cover .meta, .cover .hint { font-size: 9pt; color: var(--muted); margin: 1px 0; }
  h1 { font-size: 16pt; margin: 0 0 8px; }
  h2 { font-size: 12.5pt; margin: 13px 0 5px; border-bottom: 1px solid var(--line); padding-bottom: 2px; }
  h3 { font-size: 11pt; margin: 10px 0 4px; }
  h4 { font-size: 10pt; margin: 8px 0 3px; }
  p { margin: 3px 0; }
  ul, ol { margin: 3px 0 3px 18px; }
  li { margin: 1px 0; }
  a { color: #123a6b; text-decoration: none; }
  code { font-family: "Liberation Mono", "DejaVu Sans Mono", monospace; font-size: 8.5pt; background: #f2f2f2; padding: 0 2px; border-radius: 3px; }
  pre { background: #f6f6f6; border: 1px solid var(--line); border-radius: 4px; padding: 6px 8px; overflow-x: auto; white-space: pre-wrap; word-wrap: break-word; page-break-inside: avoid; margin: 5px 0; }
  pre code { background: none; padding: 0; font-size: 8pt; line-height: 1.25; }
  table { border-collapse: collapse; width: 100%; margin: 6px 0 10px; font-size: 8.5pt; page-break-inside: avoid; }
  th, td { border: 1px solid #999; padding: 3px 6px; text-align: left; vertical-align: top; }
  th { background: #eee; }
  blockquote { margin: 6px 0; padding: 1px 10px; border-left: 3px solid var(--line); color: #333; }
  hr { border: none; border-top: 1px solid var(--line); margin: 12px 0; }
  .adm { border: 1px solid var(--line); border-left-width: 4px; border-radius: 4px; padding: 5px 10px; margin: 8px 0; page-break-inside: avoid; }
  .adm-title { font-weight: bold; margin: 0 0 3px; }
  .adm-note, .adm-info { border-left-color: #4a76c4; background: #f2f6fd; }
  .adm-tip { border-left-color: #2e9e5b; background: #f0faf4; }
  .adm-warning, .adm-caution { border-left-color: #d98a1a; background: #fdf6ea; }
  .adm-danger { border-left-color: #c0392b; background: #fdf1f0; }
  .toc { page-break-after: always; }
  .toc ol { list-style: none; margin-left: 0; }
  .toc li { margin: 3px 0; font-size: 11pt; }
  .chapter { page-break-before: always; }
  .chapter h1 { border-bottom: 2px solid #111; padding-bottom: 6px; }
  @media print {
    body { margin: 0; padding: 0; max-width: none; }
    a { color: #000; }
    .cover .hint { display: none; }
    @page { size: A4; margin: 16mm 15mm; }
  }
`;

const html = `<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Python Bridge – Addon-Dokumentation</title>
<meta name="description" content="Vollständige, druckbare Addon-Dokumentation der Python Bridge für Godot 4.">
<style>${css}</style>
</head>
<body>
<header class="cover">
  <h1>Python Bridge</h1>
  <p class="subtitle">Vollständige Addon-Dokumentation – Python natürlich in Godot 4 integrieren</p>
  <p class="meta">Stand: ${generated} · Online: <a href="${SITE_URL}/">${SITE_URL.replace('https://', '')}</a></p>
  <p class="hint">Tipp: Über die Druckfunktion des Browsers (Strg/Cmd + P) als PDF speichern. Seitenumbrüche sind gesetzt.</p>
</header>
<nav class="toc">
  <h2>Inhalt</h2>
  <ol>
${toc}
  </ol>
</nav>
<main>
${sections}
</main>
</body>
</html>
`;

fs.mkdirSync(staticDir, { recursive: true });
fs.writeFileSync(outHtml, html, 'utf8');
console.log(`[export] HTML geschrieben: ${path.relative(repoRoot, outHtml)} (${chapters.length} Kapitel)`);

// ---------------------------------------------------------------------- pdf
if (wantPdf) {
  const soffice = ['soffice', 'libreoffice'].find((cmd) => {
    try {
      execSync(`command -v ${cmd}`, { stdio: 'ignore' });
      return true;
    } catch {
      return false;
    }
  });
  if (!soffice) {
    console.warn('[export] LibreOffice (soffice) nicht gefunden – PDF übersprungen. HTML kann im Browser gedruckt werden.');
  } else {
    try {
      execFileSync(
        soffice,
        [
          '--headless',
          `-env:UserInstallation=file://${path.join(os.tmpdir(), 'pb-soffice-profile')}`,
          '--convert-to', 'pdf',
          '--outdir', staticDir,
          outHtml,
        ],
        { stdio: 'inherit', timeout: 180000 },
      );
      console.log(`[export] PDF geschrieben: ${path.relative(repoRoot, outPdf)}`);
    } catch (error) {
      console.warn(`[export] PDF-Konvertierung fehlgeschlagen: ${error.message}`);
    }
  }
}
