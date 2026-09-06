import React from 'react';
import Link from '@docusaurus/Link';
import Layout from '@theme/Layout';
import Heading from '@theme/Heading';
import styles from './index.module.css';

const features = [
  {
    title: 'Echter Python-Code',
    text: 'Schreibe normale Python-Dateien. Die Bridge übernimmt Prozesse, Kommunikation und Fehlerbehandlung.',
  },
  {
    title: 'Godot-native Nutzung',
    text: 'GDScript bleibt die einfache Schnittstelle mit await, strukturierten Ergebnissen und Main-Thread-Synchronisation.',
  },
  {
    title: 'Für große Daten vorbereitet',
    text: 'Binary Frames, DataRefs und file-basierte Pfade vermeiden unnötige JSON-Kopien bei großen Ergebnissen.',
  },
];

export default function Home() {
  return (
    <Layout
      title="Python Bridge für Godot 4"
      description="Python natürlich in Godot 4 integrieren."
    >
      <header className={styles.hero}>
        <div className="container">
          <div className={styles.heroContent}>
            <p className={styles.eyebrow}>Godot 4 Addon</p>
            <Heading as="h1">Python Bridge</Heading>
            <p className={styles.subtitle}>
              Python natürlich in Godot 4 integrieren – transparent, asynchron
              und ohne proprietäre Python-Sprache.
            </p>
            <div className={styles.buttons}>
              <Link className="button button--primary button--lg" to="/docs/installation">
                Installation starten
              </Link>
              <Link className="button button--secondary button--lg" to="/docs/getting-started">
                Hello World öffnen
              </Link>
            </div>
          </div>
        </div>
      </header>

      <main>
        <section className="container padding-vert--xl">
          <div className="row">
            {features.map((feature) => (
              <div className="col col--4" key={feature.title}>
                <div className={styles.featureCard}>
                  <Heading as="h2">{feature.title}</Heading>
                  <p>{feature.text}</p>
                </div>
              </div>
            ))}
          </div>
        </section>

        <section className={styles.architecture}>
          <div className="container padding-vert--xl">
            <div className="row row--align-center">
              <div className="col col--6">
                <p className={styles.eyebrow}>Architekturprinzip</p>
                <Heading as="h2">Godot und Python bleiben getrennt – und arbeiten trotzdem zusammen.</Heading>
                <p>
                  Godot kontrolliert Lifecycle, Tasks und Frames. Python bleibt
                  eine normale Runtime mit Zugriff auf sein eigenes Ökosystem.
                </p>
              </div>
              <div className="col col--6">
                <pre className={styles.diagram}><code>{`GDScript
   ↓
PythonBridge
   ↓
WebSocket-Control-Channel
   ↓
Python Runtime`}</code></pre>
              </div>
            </div>
          </div>
        </section>
      </main>
    </Layout>
  );
}
