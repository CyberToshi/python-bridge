// @ts-check
// Docusaurus configuration for the Python Bridge documentation site.

const config = {
  title: 'Python Bridge',
  tagline: 'Python natürlich in Godot 4 integrieren',
  favicon: 'img/favicon.svg',

  url: 'https://cybertoshi.github.io',
  baseUrl: '/python-bridge/',
  organizationName: 'CyberToshi',
  projectName: 'python-bridge',
  onBrokenLinks: 'throw',
  onBrokenMarkdownLinks: 'warn',

  i18n: {
    defaultLocale: 'de',
    locales: ['de'],
  },

  presets: [
    [
      'classic',
      /** @type {import('@docusaurus/preset-classic').Options} */
      ({
        docs: {
          routeBasePath: 'docs',
          sidebarPath: require.resolve('./sidebars.js'),
          showLastUpdateTime: true,
          showLastUpdateAuthor: false,
          editUrl: undefined,
        },
        blog: {
          showReadingTime: true,
          blogTitle: 'Python Bridge Blog',
          blogDescription: 'Neuigkeiten, technische Hintergründe und Releases.',
        },
        theme: {
          customCss: require.resolve('./src/css/custom.css'),
        },
      }),
    ],
  ],

  themeConfig:
    /** @type {import('@docusaurus/preset-classic').ThemeConfig} */
    ({
      image: 'img/python-bridge-social-card.svg',
      navbar: {
        title: 'Python Bridge',
        logo: {
          alt: 'Python Bridge Logo',
          src: 'img/logo.svg',
        },
        items: [
          {
            type: 'docSidebar',
            sidebarId: 'tutorialSidebar',
            position: 'left',
            label: 'Dokumentation',
          },
          {
            to: '/docs/editor-ui',
            label: 'Godot-Integration',
            position: 'left',
          },
          {
            to: '/docs/api',
            label: 'API',
            position: 'left',
          },
          {
            to: '/blog',
            label: 'Blog',
            position: 'left',
          },
          {
            href: 'https://github.com/CyberToshi/python-bridge',
            label: 'GitHub',
            position: 'right',
          },
        ],
      },
      footer: {
        style: 'dark',
        links: [
          {
            title: 'Dokumentation',
            items: [
              {
                label: 'Erste Schritte',
                to: '/docs/getting-started',
              },
              {
                label: 'Godot-Integration',
                to: '/docs/editor-ui',
              },
              {
                label: 'Installation',
                to: '/docs/installation',
              },
              {
                label: 'API',
                to: '/docs/api',
              },
              {
                label: 'Gesamtdokumentation (PDF)',
                href: 'https://cybertoshi.github.io/python-bridge/PythonBridge_Dokumentation.pdf',
              },
              {
                label: 'Gesamtdokumentation (HTML, druckbar)',
                href: 'https://cybertoshi.github.io/python-bridge/PythonBridge_Dokumentation.html',
              },
            ],
          },
          {
            title: 'Projekt',
            items: [
              {
                label: 'GitHub',
                href: 'https://github.com/CyberToshi/python-bridge',
              },
              {
                label: 'Blog',
                to: '/blog',
              },
            ],
          },
        ],
        copyright: `Copyright © ${new Date().getFullYear()} Python Bridge. Gebaut mit Docusaurus.`,
      },
      prism: {
        additionalLanguages: ['gdscript'],
      },
      colorMode: {
        respectPrefersColorScheme: true,
      },
    }),
};

module.exports = config;
