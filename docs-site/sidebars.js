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
      ],
    },
    'konfiguration',
    'python-seite',
    'datenebene',
    {
      type: 'category',
      label: 'API-Referenz',
      collapsed: false,
      items: [
        'api',
        'api-tasks',
        'api-data',
        'api-internals',
        'api-editor',
      ],
    },
    'godot-verification',
    'architecture',
    'hochleistungspfade',
    'fehlerbehebung',
  ],
};

module.exports = sidebars;
