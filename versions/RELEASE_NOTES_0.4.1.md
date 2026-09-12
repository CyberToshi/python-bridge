# Release 0.4.1 – Node-Editor repariert, Syntax-Highlighting korrigiert

**Datum:** 12.09.2026 · **Vorherige Version:** 0.4.0

---

## Kurzfassung

| Was | Für wen |
|---|---|
| **Orchestrator-Node-Editor: Knoten löschen, verschieben, verbinden – alles funktional** | Alle, die den visuellen Task-Graphen nutzen |
| **Unsichtbare/übereinander liegende Knoten nach „Aktualisieren" behoben** | Alle – vorher war der Graph nach einem Refresh kaputt |
| **Python-Editor: Ziffern in Namen (`x2`, `a1b`) falsch eingefärbt** | Alle, die den Python-Dock-Editor nutzen |
| **Doku: Direktverbindung per LAN-Kabel dokumentiert** | Setup ohne Router |

---

## 1. Node-Editor (Orchestrator-Dock)

Vier konkrete Defekte:

1. **Knoten ließen sich nicht löschen** – das Delete-Signal des GraphEdit war
   nicht angebunden. Entf löscht jetzt Task- und Server-Knoten (inkl.
   zugehörigem Worker/Server im Kern); der **Router bleibt geschützt**.
2. **Unsichtbare Knoten / Alles-aufeinander nach „Aktualisieren"** – beim
   Rebuild hießen sterbende Knoten noch einen Frame so wie die neuen, die
   deshalb übersprungen oder umbenannt wurden. Die Knoten werden jetzt vor dem
   Entfernen sofort umbenannt; der Rebuild ist deterministisch.
3. **Verschobene Positionen gingen verloren** – Drag-Positionen werden jetzt in
   das Graph-Modell geschrieben und überleben Refresh, Speichern und Laden.
4. **Verbindungen nicht editierbar** – neu gezogene Verbindungen landen im
   Modell (bleiben gespeichert), gelöste werden entfernt. Fallback-Positionen
   für neue Server sind jetzt deterministisch statt zufällig überlappend.

## 2. Python-Editor (Syntax-Highlighting)

`x2` oder `a1b` färbte die Ziffer als Zahl, weil Bezeichner-Scan und
Zahl-Erkennung beide ohne Digit-Prüfung griffen. Ziffern zählen jetzt zu
Bezeichnern; Zahlen, Hex/Oktal/Binär und Exponenten verhalten sich unverändert.

## 3. Doku

* **Direktes LAN-Kabel** zwischen Hauptrechner und Client als eigene Variante
  beschrieben (funktioniert ohne Router: Auto-MDIX + Link-Local-Adressen,
  Discovery sendet an `255.255.255.255`).
* Client-Setup um Firewall-/TLS-Erststart-Schritte und Kurz-Check erweitert.
* Tests des Panels sind jetzt hermetisch (ein echtes `orchestrator_workers.json`
  im Projekt verfälschte sie) und decken Löschen, Positionen und Verbindungen ab.

---

## Tests (alle grün)

```text
Orchestrator-Kern + Routing + Panel: 413 passed, 0 failed
Transport-E2E · Cluster-E2E (Discovery + Datei-Cache) · TLS-E2E: ERFOLG
Worker-UI 36 passed · Release-Paket 21 passed
```
