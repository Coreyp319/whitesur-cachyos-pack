#!/usr/bin/env python3
"""Instantiate Plasma QML config UIs in the REAL Qt engine.

qmllint validates syntax but not construction: an invalid signal handler (e.g.
`onRunningChanged` on a ColorAnimation) passes lint yet throws at create(),
which silently blanks a Plasma wallpaper config dialog. This calls
QQmlComponent.create() on each file and fails if any returns null or errors.

Usage:  QT_QPA_PLATFORM=offscreen python3 qml_instantiate.py <file.qml> ...
Exit 0 if all instantiate, 1 otherwise.
"""
import sys
from PyQt6.QtCore import QUrl
from PyQt6.QtGui import QGuiApplication
from PyQt6.QtQml import QQmlComponent, QQmlEngine

app = QGuiApplication(["qml-instantiate-test"])
engine = QQmlEngine()
engine.addImportPath("/usr/lib/qt6/qml")
# config.qml binds `twinFormLayouts: parentLayout`, a Plasma-injected context
# property. Stub it so its (expected) absence isn't counted as a failure.
engine.rootContext().setContextProperty("parentLayout", None)

failed = 0
for path in sys.argv[1:]:
    comp = QQmlComponent(engine, QUrl.fromLocalFile(path))
    obj = comp.create()
    errs = [e.toString() for e in comp.errors() if "parentLayout" not in e.toString()]
    if obj is None or errs:
        print(f"  FAIL {path}")
        for e in errs:
            print(f"       {e}")
        if obj is None and not errs:
            print("       create() returned None (component failed to construct)")
        failed += 1
    else:
        print(f"  PASS {path}")

sys.exit(1 if failed else 0)
