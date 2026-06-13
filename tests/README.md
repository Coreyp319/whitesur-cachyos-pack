# Tests

Static + real-engine sanity checks over the whole pack. No framework — just a
bash runner that shells out to the tools already used during development.

```bash
bash tests/run.sh      # exit 0 = all pass
```

What it checks (each degrades to **SKIP** if its tool is missing, so it still
runs useful on a machine without Qt/PyQt6):

| Check | Tool | Catches |
|---|---|---|
| Shell syntax | `bash -n` | broken installer/revert scripts |
| Python compile | `py_compile` | broken bridges / KRunner runner |
| SVG well-formedness | `xmllint` | malformed Kvantum theme / icon SVGs |
| JSON / XML validity | `python json` / `xmllint` | bad metadata.json, config.json, main.xml |
| **QML instantiation** | `PyQt6` | **construction-time QML errors that `qmllint` misses** |

The QML instantiation check (`qml_instantiate.py`) constructs the aurora
wallpaper config UI in a real Qt engine via `QQmlComponent.create()`. `qmllint`
validates syntax but not construction — e.g. an invalid signal handler passes
lint yet throws at create() and silently blanks the Plasma config dialog. This
test is what catches that class of bug.
