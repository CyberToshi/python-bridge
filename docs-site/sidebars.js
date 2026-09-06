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
    'api',
    'godot-verification',
    'architecture',
    'hochleistungspfade',
    'high-performance-paths',
    'fehlerbehebung',
  ],
};

module.exports = sidebars;
