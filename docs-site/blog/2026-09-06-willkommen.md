---
slug: willkommen
title: Willkommen bei Python Bridge
authors: [python-bridge-team]
tags: [release, godot, python]
date: 2026-09-06
---

# Willkommen bei Python Bridge

**Python Bridge** verbindet Godot 4 mit Python — ohne Python in eine eigene
Sprache zu verwandeln. Du schreibst weiterhin normale `.py`-Dateien, und
GDScript bleibt deine einfache Godot-Schnittstelle.

<!-- truncate -->

## Was die Bridge heute schon kann

- Python-Prozesse starten, überwachen und sauber beenden
- asynchrone Tasks mit Prioritäten, Batching und Backpressure
- strukturierte Fehler inklusive Python-Traceback in Godot
- mehrere Python-Instanzen und Worker-Slots parallel
- automatische projektbezogene `venv` mit Dependency-Verwaltung
- Hot Reload von Python-Code aus dem Godot-Editor
- DataRefs und Datei-Transport für große numerische Ergebnisse
- Crash-Restart mit exponentiellem Backoff und Health Monitoring

## Der aktuelle Stand

Die Python-Runtime ist durch eine umfassende Testsuite abgedeckt
(90 Tests grün). Die Godot-Integration folgt der Verifikations-Checkliste
in der [Dokumentation](/docs/godot-verification).

## Was als Nächstes kommt

1. End-to-End-Verifikation der Godot-Integration im Editor (P0)
2. Verifikation des Shared-Memory-Datenpfads aus Godot heraus
3. Automatisierte Builds für den GDExtension-Hochleistungspfad

Der einfachste Einstieg ist das
[Hello-World-Beispiel](/docs/getting-started) — Godot startet Python dabei
selbst, du brauchst kein Terminal.
