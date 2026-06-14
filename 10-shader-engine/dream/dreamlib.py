#!/usr/bin/env python3
"""Guardrails for the Layer-10 dreaming journey — the model proposes, THIS disposes.

Pure validation/clamp logic (no engine, no I/O beyond what callers pass in) so it's
unit-testable offline and a bad manifest can never reach the bevy composer. Mirrors the
trust boundary of `6-local-ai/ui-audit/`: a deny-by-default **catalog allowlist** (only
known CC0 ids / procedural kinds), **bounds clamping** (no 500 m prop, no runaway light),
**schema validation**, and **seam-aperture** alignment so a new leg can't step off the
previous one.

`validate_leg(manifest, catalog, prev_exit)` returns:
    { ok, rejected, reason, sanitized, issues }
where `sanitized` is the manifest with unknown assets dropped/substituted and out-of-range
values clamped (None when rejected), and `issues` is a list of
    { level: "clamp"|"drop"|"reject"|"warn", field, detail }.
A leg is **rejected** (not applied) only for unfixable problems — broken schema, an
unknown geometry kind, or a seam the chaining can't hide. Everything else is fixed in
place and logged, so the journey keeps moving.
"""
from __future__ import annotations

import copy
import json
from pathlib import Path
from typing import Any, Optional


# --------------------------------------------------------------------------- #
# small helpers
# --------------------------------------------------------------------------- #

def _num(v: Any) -> Optional[float]:
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def _clamp(v: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, v))


def _rng(bounds: dict, name: str, dlo: float, dhi: float) -> tuple[float, float]:
    b = bounds.get(name, {}) or {}
    return (float(b.get("min", dlo)), float(b.get("max", dhi)))


def load_catalog(path: str | Path) -> dict:
    return json.loads(Path(path).read_text(encoding="utf-8"))


# --------------------------------------------------------------------------- #
# validator
# --------------------------------------------------------------------------- #

def validate_leg(manifest: Any, catalog: dict, prev_exit: Optional[dict] = None) -> dict:
    """Validate + sanitise one candidate leg manifest against the catalog.

    `prev_exit` is the previous leg's exit portal (for the seam check); None for leg-000
    or a standalone check.
    """
    issues: list[dict] = []

    def add(level: str, field: str, detail: str) -> None:
        issues.append({"level": level, "field": field, "detail": detail})

    def reject(reason: str) -> dict:
        add("reject", "leg", reason)
        return {"ok": False, "rejected": True, "reason": reason, "sanitized": None, "issues": issues}

    # 1. schema — the structural minimum the composer needs
    if not isinstance(manifest, dict):
        return reject("manifest is not a JSON object")
    for f in ("entry", "exit"):
        portal = manifest.get(f)
        if not isinstance(portal, dict) or "at" not in portal or "forward" not in portal:
            return reject(f"missing/invalid '{f}' portal (need at + forward)")
    geom = manifest.get("geometry", [])
    if not isinstance(geom, list) or not geom:
        return reject("'geometry' must be a non-empty list")

    sanitized = copy.deepcopy(manifest)
    bounds = catalog.get("bounds", {})
    kinds = catalog.get("geometry_kinds", {})
    stone = catalog.get("stone", {})
    models = catalog.get("models", {})
    default_stone = next(iter(stone), None)
    tol = float(bounds.get("aperture_tol", 0.1))

    # 2. geometry — kind must be known; params clamped; unknown stone → default
    out_geom = []
    for g in geom:
        if not isinstance(g, dict):
            return reject("geometry entry is not an object")
        kind = g.get("kind")
        spec = kinds.get(kind)
        if spec is None:
            return reject(f"unknown geometry kind {kind!r} (not in catalog)")
        gg = dict(g)
        for pname, prange in spec.get("params", {}).items():
            if pname in gg:
                v = _num(gg[pname])
                if v is None:
                    gg[pname] = prange["default"]
                    add("clamp", f"geometry.{pname}", f"non-numeric → default {prange['default']}")
                else:
                    cv = _clamp(v, prange["min"], prange["max"])
                    if abs(cv - v) > 1e-9:
                        add("clamp", f"geometry.{pname}", f"{v} → {cv} (range {prange['min']}..{prange['max']})")
                    gg[pname] = cv
        for slot in spec.get("materials", []):
            mid = gg.get(slot)
            if mid is not None and mid not in stone:
                if default_stone is None:
                    return reject(f"unknown stone {mid!r} and no catalog default to fall back on")
                add("drop", f"geometry.{slot}", f"unknown stone {mid!r} → default {default_stone!r}")
                gg[slot] = default_stone
        out_geom.append(gg)
    sanitized["geometry"] = out_geom

    # 3. cross-section consistency — corridor (width,height) must match its portals'
    #    apertures, else the composer would render a corridor wider/taller than its
    #    opening. Clamp the apertures to the geometry (the load-bearing dimension).
    corr = next((g for g in out_geom if g.get("kind") == "corridor"), None)
    if corr is not None:
        want = [_num(corr.get("width")), _num(corr.get("height"))]
        if None not in want:
            for portal in ("entry", "exit"):
                ap = sanitized[portal].get("aperture")
                if not (isinstance(ap, list) and len(ap) == 2):
                    sanitized[portal]["aperture"] = want
                    add("clamp", f"{portal}.aperture", f"missing → {want} (corridor cross-section)")
                elif abs(_num(ap[0]) - want[0]) > tol or abs(_num(ap[1]) - want[1]) > tol:
                    add("clamp", f"{portal}.aperture", f"{ap} → {want} (match corridor cross-section)")
                    sanitized[portal]["aperture"] = want

    # 4. seam — this entry's aperture must match the previous leg's exit aperture, else
    #    the join would step (the chaining aligns position+direction, NOT cross-section).
    if prev_exit is not None:
        pe = prev_exit.get("aperture")
        en = sanitized["entry"].get("aperture")
        if isinstance(pe, list) and isinstance(en, list) and len(pe) == 2 and len(en) == 2:
            if abs(_num(pe[0]) - _num(en[0])) > tol or abs(_num(pe[1]) - _num(en[1])) > tol:
                return reject(f"seam: entry aperture {en} != previous exit {pe} (join would step)")

    # 5. props — drop unknown models; clamp pos + scale
    sx_lo, sx_hi = _rng(bounds, "prop_scale", 0.1, 6.0)
    xz_lo, xz_hi = _rng(bounds, "prop_pos_xz", -8.0, 8.0)
    y_lo, y_hi = _rng(bounds, "prop_pos_y", -1.0, 12.0)
    out_props = []
    for p in manifest.get("props", []) or []:
        mid = (p or {}).get("model")
        if mid not in models:
            add("drop", "props.model", f"unknown model {mid!r} dropped (not in catalog)")
            continue
        pp = dict(p)
        sc = _num(pp.get("scale", 1.0))
        sc = 1.0 if sc is None else sc
        csc = _clamp(sc, sx_lo, sx_hi)
        if abs(csc - sc) > 1e-9:
            add("clamp", "props.scale", f"{mid}: {sc} → {csc}")
        pp["scale"] = csc
        pos = pp.get("pos", [0.0, 0.0, 0.0])
        if isinstance(pos, list) and len(pos) == 3:
            cp = [
                _clamp(_num(pos[0]) or 0.0, xz_lo, xz_hi),
                _clamp(_num(pos[1]) or 0.0, y_lo, y_hi),
                _clamp(_num(pos[2]) or 0.0, -10000.0, 10000.0),  # z runs the corridor; only sanity-bound
            ]
            if any(abs(cp[i] - (_num(pos[i]) or 0.0)) > 1e-9 for i in range(3)):
                add("clamp", "props.pos", f"{mid}: {pos} → {cp}")
            pp["pos"] = cp
        out_props.append(pp)
    sanitized["props"] = out_props

    # 6. lights — clamp intensity + range (kind is advisory; the composer treats all
    #    manifest lights as point lights)
    li_lo, li_hi = _rng(bounds, "light_intensity", 0.0, 400000.0)
    lr_lo, lr_hi = _rng(bounds, "light_range", 0.5, 40.0)
    out_lights = []
    for l in manifest.get("lights", []) or []:
        ll = dict(l)
        for field, lo, hi in (("intensity", li_lo, li_hi), ("range", lr_lo, lr_hi)):
            v = _num(ll.get(field))
            if v is not None:
                cv = _clamp(v, lo, hi)
                if abs(cv - v) > 1e-9:
                    add("clamp", f"lights.{field}", f"{v} → {cv}")
                ll[field] = cv
        out_lights.append(ll)
    sanitized["lights"] = out_lights

    # 7. atmosphere — clamp the scalar dials
    atmos = dict(manifest.get("atmosphere", {}) or {})
    for field, bname, dlo, dhi in (
        ("fog_density", "fog_density", 0.0, 0.05),
        ("fog_volume_density", "fog_volume_density", 0.0, 0.2),
        ("ambient_brightness", "ambient_brightness", 0.0, 200.0),
        ("moon_illuminance", "moon_illuminance", 0.0, 20000.0),
    ):
        if field in atmos:
            v = _num(atmos[field])
            lo, hi = _rng(bounds, bname, dlo, dhi)
            if v is not None:
                cv = _clamp(v, lo, hi)
                if abs(cv - v) > 1e-9:
                    add("clamp", f"atmosphere.{field}", f"{v} → {cv}")
                atmos[field] = cv
    sanitized["atmosphere"] = atmos

    return {"ok": True, "rejected": False, "reason": "", "sanitized": sanitized, "issues": issues}


def summarize_issues(issues: list[dict]) -> dict:
    """Count issues by level — for ledger + report."""
    out: dict[str, int] = {}
    for i in issues:
        out[i["level"]] = out.get(i["level"], 0) + 1
    return out
