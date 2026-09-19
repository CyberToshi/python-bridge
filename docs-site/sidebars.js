// Sidebar configuration for the Python Bridge documentation.

/** @type {import('@docusaurus/plugin-content-docs').SidebarsConfig} */
const sidebars = {
  tutorialSidebar: [
    'intro',
    {
      type: 'category',
      label: 'Erste Schritte',
      collapsed: false,
      items: [
        'installation',
        'getting-started',
        'editor-ui',
        'export-check',
        'web-runtime',
        'cython',
      ],
    },
    'konfiguration',
    'python-seite',
    'datenebene',
    'api',
    'godot-verification',
    'architecture',
    'hochleistungspfade',
    'fehlerbehebung',
  ],
};

module.exports = sidebars;
