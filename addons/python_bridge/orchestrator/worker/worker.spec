# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller-Spezifikation fuer die Worker-Anwendung (V1).

Damit laesst sich ein **eigenstaendiges Programm** bauen, das auf einem
Client-Rechner ohne Python-Installation laeuft:

    Windows:  pyinstaller --noconfirm worker.spec   ->  dist/Worker.exe
    Linux:    pyinstaller --noconfirm worker.spec   ->  dist/Worker

Der Build muss auf dem jeweiligen Zielsystem erfolgen (PyInstaller kann nicht
cross-compilieren).

Wichtig: Die App startet `orchestrator_worker.py` als **Unterprozess**. Deshalb
muessen alle Module daneben liegen, die dieser importiert - sonst bricht der
gebaute Worker mit "FEHLER: <modul>.py fehlt" und Fehlercode 2 ab:

    orchestrator_worker.py   der Worker selbst
    python_build.py          Umgebung/Build (Cython)
    file_store.py            Datei-Empfang (Chunks, SHA-256)
    tls_cert.py              selbstsigniertes TLS-Zertifikat
"""

block_cipher = None

a = Analysis(
    ['worker_app.py'],
    pathex=[],
    binaries=[],
    datas=[
        ('orchestrator_worker.py', '.'),
        ('python_build.py', '.'),
        ('file_store.py', '.'),
        ('tls_cert.py', '.'),
    ],
    hiddenimports=['websockets', 'websockets.asyncio.server', 'websockets.server'],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)
pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.zipfiles,
    a.datas,
    [],
    name='Worker',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=False,          # kein Konsolenfenster
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
