# Python Bridge

**Run Python natively inside Godot 4.** This addon executes your Python code
in a project-local virtual environment and connects it to GDScript over
WebSocket.

## Features

- Python process instances with automatic `venv` creation and `pip` setup
- Frame-synced calls, awaitable results and error handling from GDScript
- Task manager with batching, backpressure and per-frame decode budgets
- Health monitoring with automatic crash restart
- In-editor Python dock: multi-file editor, syntax highlighting, wrapper
  generation, hot reload
- Optional high-performance path (GDScript → C++ → GDExtension)

## Requirements

- Godot 4.2+ (verified with 4.7.x)
- Python 3.8+ (verified with 3.12/3.13)

## Installation

1. Copy the `addons/python_bridge/` folder into your project's `addons/`
   directory.
2. Enable the plugin under **Project → Project Settings → Plugins**.
3. Start your first instance:

```gdscript
var result: PythonBridgeResult = await PythonBridge.start_instance("default")
```

## Documentation

Full documentation (German): https://cybertoshi.github.io/python-bridge/

## License

MIT – see [LICENSE](LICENSE).
