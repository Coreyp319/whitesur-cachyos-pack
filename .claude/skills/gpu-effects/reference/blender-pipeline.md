# Blender authoring pipeline — hero assets for Layer 9 & 10

This pack authors 3-D **"hero" assets** (glowing neon cores, Big-Sur abstract
forms) in **Blender, driven entirely by Python over the `blender-mcp` bridge** —
the agent *sends `bpy` code* to a running Blender; it almost never touches the UI.
One source object feeds **two output paths**, and the rules differ per path —
that distinction drives most of this doc:

| Path | Consumer | Output | Glow comes from |
|---|---|---|---|
| **A — sprite sheet** | Layer 9 aurora wallpaper (`9-gpu-effects/interactive-bg/contents/assets/hero_core.png`) | 16-frame turntable PNG atlas, transparent bg, rendered in **EEVEE** | Blender (Compositor **Glare** node) **+** the wallpaper's own `bloom.frag` |
| **B — glTF** | Layer 10 `nimbus-flux` (`10-shader-engine/nimbus-flux/assets/hero_core.glb`) | **GLB**, PBR + emissive | **bevy** (HDR camera + `Bloom`), *not* Blender |

**Read §0 before writing any bpy** — it's the operating reality, the live-verified
facts about this exact build, and the cross-cutting golden rules. §1–§5 are
reference depth. Cross-references like "(§5)" point between sections.

**Contents**
- **§0 — Read first: the operating environment** (bridge, verified facts, sandbox, golden rules)
- **§1 — bpy / Python automation** (data-vs-ops, idempotent builds, bmesh, materials-by-code, pitfalls)
- **§2 — Modeling, geometry & scene hygiene** (topology, transforms, modifiers, geometry nodes, poly budget, orphans)
- **§3 — Materials & shading** (Principled BSDF, EEVEE vs Cycles, emission/neon, glass, color management, baking)
- **§4 — Lighting, camera & rendering** (3-point rig, world/HDRI, camera aim/fit, transparent EEVEE render, turntable + atlas)
- **§5 — glTF export for real-time / bevy** (axes & scale, what survives, emissive, exporter settings, bevy load, validation)

---

## 0. Read first — the operating environment

### The blender-mcp bridge — how your code actually runs
The bridge `exec()`s your code inside a Blender **timer callback**, not a real UI
event. Verified live on this instance: `bpy.context.window`/`screen` exist, but
**`bpy.context.area is None` and `bpy.context.region is None`**. Consequences:
- Operators whose `poll()` needs a 3-D viewport **fail immediately**
  (`bpy.ops.view3d.*` → `RuntimeError: ...poll() failed, context is incorrect`).
  Scene-level ops (`mesh.primitive_cube_add`, `render.render`, `export_scene.gltf`,
  `transform_apply` under `temp_override`) work.
- **State persists across calls** (same Python process) — module globals survive,
  objects accumulate. Don't assume a clean slate; **reset explicitly** (§1).
- Keep each code send self-contained and modest; the bridge can time out on long
  ops or drop the very first command. Split big builds into steps.
- **Stdout is your only feedback channel** — end every probe/build with
  `print(...)` of a JSON/string result.

### This exact build — live-verified facts (flatpak Blender **5.1.2**)
Probed directly against the running instance — trust these over generic docs:
- **Render engine is `BLENDER_EEVEE` and it is the *only* engine** —
  `engines == ["BLENDER_EEVEE"]`. **No Cycles, no Workbench.** ⚠️ This means
  **in-Blender texture baking is unavailable** (the Bake panel is Cycles-only):
  the "bake procedurals to images before glTF export" advice in §3/§5 requires
  installing a **Cycles-enabled** Blender build. On the stock flatpak, instead
  author with image textures from the start, or keep glTF materials to solid
  factors + emission and let procedural richness live only on the EEVEE sprite path.
  (The engine id is `BLENDER_EEVEE` in 5.0+; it was `BLENDER_EEVEE_NEXT` in 4.2–4.5.)
- **EEVEE "Bloom" is gone** — `scene.eevee.use_bloom` does not exist. Glow on the
  sprite path = the **Compositor Glare** node (§3/§4).
- **Compositor API changed** — `scene.node_tree` is **absent**; use
  `scene.compositing_node_group` + `bpy.data.node_groups` (§3). But
  `material.use_nodes` and `world.use_nodes` **still exist and default to True**
  (the web claim that they were removed did *not* land in this build) — fresh
  materials already have a node tree; setting `use_nodes=True` is harmless/optional.
- **Principled BSDF** exposes `Emission Color` / `Emission Strength` (the 4.0+ v2
  names; the old `"Emission"` raises `KeyError`).
- Only **`bpy.ops.export_scene.gltf`** exists (no `bpy.ops.wm.export.*`); the glTF
  exporter addon `io_scene_gltf2` is enabled.
- `bpy.ops.outliner.orphans_purge(do_recursive=True)` polls fine.

### Flatpak sandbox + verify-by-file
- **The sandbox cannot see host `/tmp`.** Render/export to **`$HOME`** (resolves to
  the real `/home/corey`); `os.makedirs(path, exist_ok=True)` first or the write
  silently no-ops.
- **You cannot see the viewport** — `get_viewport_screenshot` fails in the sandbox.
  **Render a PNG to disk and `Read` it back; assert it exists with non-zero size.**
  "render returned" ≠ "file written with content." This is non-negotiable: every
  build ends in a proof render you actually look at.

### Reaching / starting Blender — and your lane
The MCP server (`uvx blender-mcp`, registered in repo `.mcp.json`) only talks to a
**running** Blender whose addon socket is on **your lane**:
`localhost:${NIMBUS_BLENDER_PORT:-9876}`. The repo `.mcp.json` routes the `blender`
server to that same env var, so a single `export NIMBUS_BLENDER_PORT=<port>` wires
*both* the MCP tools and the Blender instance to the same lane. Addon lives at
`~/.var/app/org.blender.Blender/config/blender/5.1/scripts/addons/blender_mcp_addon.py`.

**Start/stop your lane with the forge launcher** (idempotent up/down — the authoring
analogue of install/revert, never installed onto an end user's box):
```bash
.claude/skills/gpu-effects/blender-mcp.sh up                          # this lane (default 9876)
NIMBUS_BLENDER_PORT=9877 .claude/skills/gpu-effects/blender-mcp.sh up # a sibling agent's lane
```
Under the hood it runs the documented headless auto-start, with the lane's port set
before the addon's `StartServer` op fires (it reads `scene.blendermcp_port` at start):
```bash
setsid -f flatpak run org.blender.Blender --python-expr "import bpy; \
  bpy.ops.preferences.addon_enable(module='blender_mcp_addon'); \
  bpy.context.scene.blendermcp_port=$NIMBUS_BLENDER_PORT; \
  bpy.app.timers.register(lambda: bpy.ops.blendermcp.start_server() and None, first_interval=1.5)"
```

**Multi-agent reality:** you may be one of several agents sharing this host, each on
its own lane (9876 canonical, 9877+ for parallel agents), and **each lane is a separate
flatpak Blender instance**. Your `bpy` tool calls already reach the right instance via
`BLENDER_PORT` — but the bridge session, the scene, and any render/export paths are
**per-instance**. Only ever touch **your own** lane and scene; never assume 9876.

### Golden rules (apply in every section)
1. **Prefer the data API (`bpy.data.*`) over `bpy.ops`** — deterministic, 25–300×
   faster in loops, no context dependence. When an op is forced, supply context via
   `bpy.context.temp_override(...)`. **Never run `bpy.ops` in a tight loop.**
2. **Reset-then-build, name deterministically, stay idempotent** — over the
   persistent bridge session, re-runs otherwise pile up `.001` duplicates.
3. **Address Principled inputs and node sockets *by name*, never by index** —
   indices shifted in the 4.0 "v2" node (index 16 is a dead no-op).
4. **Apply transforms (especially scale) before export and before relying on
   modifiers**; assert `obj.scale == (1,1,1)`. Unapplied scale is the #1 silent
   failure (wrong bevel width, broken normals, 100×-off or tilted glTF).
5. **Version-gate** anything version-sensitive with `bpy.app.version` tuples
   (socket names, engine id, compositor API) instead of assuming.
6. **Procedural textures (Noise/Voronoi/etc.) do NOT export to glTF** — bake to
   image textures first (but see the no-Cycles caveat above), or author with images.
7. **Glow is path-specific** — path A: Compositor Glare + the wallpaper's
   `bloom.frag`; path B: `Emission Strength > 1` → bevy's bloom. **Never bake glow
   into the glTF material.**
8. **The view transform bakes into 8-bit PNGs** — pick it deliberately (`Standard`
   for literal saturated neon; AgX mutes it). Irrelevant to glTF (raw values export).
9. **Verify by reading the output file, never the viewport.**

---

## 1. bpy / Python automation

Write code that works on the first send: prefer the data API, supply context
explicitly, verify by file output.

### bpy.data vs bpy.ops — prefer data, override context when ops are forced
`bpy.ops` routes through the UI/depsgraph, pushes undo, and depends on
`bpy.context` (active object, mode, area) — slow and context-fragile. The data API
is deterministic and **25–300× faster** in loops (1000 cubes: ~30 s via
`primitive_cube_add` vs sub-second via `bpy.data`).

- **Default to the data API.** Create datablocks with `bpy.data.meshes.new` /
  `bpy.data.objects.new`; set `obj.location`, `obj.matrix_world`, material inputs
  directly.
- **Ops are unavoidable** for: `transform_apply`, modifier apply/convert,
  boolean/remesh, UV unwrap, decimate, glTF export, `render.render`.
- When you must call an op, **supply context** instead of fiddling with global
  selection:
  ```python
  with bpy.context.temp_override(active_object=obj,
                                 selected_objects=[obj],
                                 selected_editable_objects=[obj]):
      bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
  ```
  Use `temp_override` (≥3.2; the old positional `override` dict is removed). In this
  headless/timer context there is **no VIEW_3D area**, so avoid viewport ops
  entirely — find a data-API equivalent.
- Wrap risky ops in `try/except RuntimeError` and `print` the message — a failed
  `poll()` is silent otherwise.

### Idempotent, deterministic scene construction
Don't trust the startup scene; build from a known state every run.
```python
import bpy
bpy.data.batch_remove(list(bpy.data.objects))        # wipe objects + their data
bpy.ops.outliner.orphans_purge(do_recursive=True)    # the cheap/reliable op (polls here)
```
Avoid `wm.read_factory_settings()`/`read_homefile()` over the bridge — they can
reset the connection the bridge holds.

Create geometry without primitive ops, link explicitly:
```python
mesh = bpy.data.meshes.new("HeroCore_mesh")          # deterministic names
mesh.from_pydata(verts, edges, faces)                # edges can be []
mesh.update()
obj = bpy.data.objects.new("HeroCore", mesh)
bpy.context.scene.collection.objects.link(obj)        # modern link pattern
```
- `bpy.data.*.new()` **de-duplicates names** (`.001`) — reset first, or
  `bpy.data.objects.get("HeroCore")` and reuse, to stay idempotent.
- An object exists nowhere until `link`ed to a collection (`scene.collection.objects`
  or a `bpy.data.collections.new(...)` nested via `parent.children.link(child)`).
- Set transforms on the object datablock (`obj.location`, `.rotation_euler`,
  `.scale`, `.matrix_world`), not via `bpy.ops.transform.*`.

### bmesh — procedural geometry essentials
Anything beyond `from_pydata` (extrude, bevel, subdivide, merge). Lifecycle:
**new → fill/edit → write back → free**.
```python
import bmesh
bm = bmesh.new()
bmesh.ops.create_icosphere(bm, subdivisions=3, radius=1.0)
bmesh.ops.bevel(bm, geom=bm.edges[:], offset=0.05, segments=3, affect='EDGES')
bm.normal_update()
mesh = bpy.data.meshes.new("Core_mesh")
bm.to_mesh(mesh)
bm.free()                 # ALWAYS free — a leaked BMesh corrupts/crashes later
obj = bpy.data.objects.new("Core", mesh)
bpy.context.scene.collection.objects.link(obj)
```
- Edit an existing mesh: `bm = bmesh.new(); bm.from_mesh(mesh); ...; bm.to_mesh(mesh); bm.free()`.
- After adding elements call `bm.verts.ensure_lookup_table()` (and `.edges`/`.faces`)
  before indexing.
- `bmesh.ops.*` take/return geometry dicts:
  `res = bmesh.ops.extrude_face_region(bm, geom=faces); new = res["geom"]`.
- Don't mix a live `bm` with `bpy.ops`; finish and `free()` first.
- `from_pydata` face winding sets normals — if it renders dark/inside-out, reverse
  the vertex order or `bmesh.ops.recalc_face_normals(bm, faces=bm.faces)`.

### Selection / active-object discipline
Operators read `context.active_object`/`selected_objects`; in the bridge these may be
stale or empty. Don't depend on global selection — pass objects via `temp_override`.
If an op needs `mode='EDIT'`, set it explicitly and restore:
```python
with bpy.context.temp_override(active_object=obj, selected_objects=[obj]):
    bpy.ops.object.mode_set(mode='EDIT'); ...; bpy.ops.object.mode_set(mode='OBJECT')
```

### Materials via Python (node tree) — version-robust
```python
def new_principled(name):
    mat = bpy.data.materials.new(name)                # already has nodes on 5.1
    nt = mat.node_tree
    bsdf = nt.nodes.get("Principled BSDF") or nt.nodes.new("ShaderNodeBsdfPrincipled")
    out  = nt.nodes.get("Material Output")  or nt.nodes.new("ShaderNodeOutputMaterial")
    nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
    return mat, nt, bsdf

def setp(bsdf, **kw):
    """Set Principled inputs by name; skip names absent in this version."""
    for k, v in kw.items():
        sock = bsdf.inputs.get(k)
        if sock is None:
            print(f"[warn] no socket {k!r} in this build"); continue
        sock.default_value = v

mat, nt, bsdf = new_principled("neon_core")
setp(bsdf, **{"Base Color": (0,0,0,1), "Metallic": 0.0, "Roughness": 0.4,
              "Emission Color": (0.1,0.6,1.0,1), "Emission Strength": 6.0})
obj.data.materials.append(mat)                         # assign via data API
```
- **Index sockets by name, not integer** (indices shift between versions).
- Principled v2 (4.0+) socket names: `Base Color`, `Metallic`, `Roughness`, `IOR`,
  `Alpha`, `Normal`, `Subsurface Weight/Radius/Scale/IOR/Anisotropy`,
  `Specular IOR Level`, `Specular Tint`, `Transmission Weight`,
  `Coat Weight/Roughness/IOR/Tint/Normal`, `Sheen Weight/Roughness/Tint`,
  **`Emission Color`**, **`Emission Strength`**, `Thin Film Thickness/IOR`. Pre-4.0
  names (`Emission`, `Specular`, `Transmission`, `Subsurface`) are gone.
- Version-gate if you ever target <4.0:
  `name = "Emission Color" if bpy.app.version >= (4,0,0) else "Emission"`.
- See §3 for the full materials treatment (EEVEE vs Cycles, color spaces, glass).

### Reading final (post-modifier) geometry — use the depsgraph
`obj.data` is the *pre-modifier* base mesh. For evaluated geometry:
```python
dg = bpy.context.evaluated_depsgraph_get()
obj_eval = obj.evaluated_get(dg)
mesh_eval = obj_eval.to_mesh()        # evaluated copy; free with obj_eval.to_mesh_clear()
```
After creating/moving objects, call `bpy.context.view_layer.update()` before reading
a child/parent `matrix_world` or rendering — the depsgraph is lazy.

### Saving / exporting / rendering — and verification
```python
bpy.ops.wm.save_as_mainfile(filepath="/home/corey/.../hero.blend")
```
- **glTF export**: only `bpy.ops.export_scene.gltf` exists here — full known-good
  call with the transform-apply preamble is in **§5**.
- **Proof render**: render a small PNG and assert it exists (full rendering recipe,
  transparent bg, turntable in **§4**):
  ```python
  sc = bpy.context.scene
  sc.render.image_settings.file_format = 'PNG'
  sc.render.image_settings.color_mode = 'RGBA'     # NOT 'RGB' — RGB drops alpha
  sc.render.film_transparent = True
  sc.render.filepath = "/home/corey/nimbus_renders/proof.png"
  bpy.ops.render.render(write_still=True)
  import os; assert os.path.getsize(sc.render.filepath) > 0
  ```

### Headless / background execution (offline/export track, outside the bridge)
```bash
blender --background --factory-startup --python build_hero.py -- --out /home/corey/hero.glb
```
- `--background`/`-b`: no UI; **viewport ops still fail** — same discipline.
- `--factory-startup`: reproducible; **enable addons explicitly** in-script:
  `import addon_utils; addon_utils.enable("io_scene_gltf2", default_set=True)`.
- `--python-exit-code 1`: non-zero exit if the script raises — essential for
  CI/agent error detection. Read your args after `--`:
  `sys.argv[sys.argv.index("--")+1:]`.

### High-leverage habits
- Wrap ops in `try/except` and surface `RuntimeError`.
- Gate version-sensitive code with `bpy.app.version`.
- No `bpy.ops` in tight loops; build via `bpy.data` and link once.
- Name everything deterministically; reset-then-build.
- Free what you allocate (`bm.free()`, `obj_eval.to_mesh_clear()`).
- Trust files, not the viewport.

---

## 2. Modeling, geometry & scene hygiene

Geometry is built procedurally (Python + modifiers), seen mostly from one angle, and
must export clean and lightweight.

### Topology basics for real-time export
- **The engine eats triangles.** glTF stores triangles; bevy/wgpu render triangles.
  Quads/n-gons are a modeling-time convenience.
- **Triangulate yourself for predictability.** N-gons (and even quads) triangulate
  differently across tools → shading/normal-map seams. Pre-triangulate, or add a
  non-applied **Triangulate** modifier so the exporter bakes a deterministic result.
  Clean up with `Tris to Quads` while modeling, Triangulate (`Beauty` for shape,
  `Fixed`/`Clip` for predictability) at the end.
- **N-gons are the real hazard, not tris.** Flat n-gons render fine but triangulate
  unpredictably → dark/banded shading. Kill all n-gons before export. Scattered tris
  on a static, non-deforming hero are fine.
- **Poles** (3- or 5+-edge verts) pinch under subdivision; keep them off
  curved/silhouette surfaces.
- **Don't over-invest.** For a hero seen from one camera: (a) n-gon-free,
  (b) dense enough on lit silhouette edges, (c) correctly normalled. Skip textbook
  all-quad purity on hidden faces.

### Scale, units & transforms — the #1 automated-agent pitfall
- **Apply transforms before export and before relying on modifiers.** Unapplied
  scale/rotation causes non-uniform Bevel/Solidify, wrong normals, warped/offset
  glTF. Via op (object selected/active, Object Mode):
  ```python
  obj = bpy.data.objects["hero_core"]
  bpy.context.view_layer.objects.active = obj; obj.select_set(True)
  bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
  # location=False keeps the hero at world origin but bakes rot+scale
  ```
  Pure-data alternative (no op/context), bakes the matrix and resets the transform:
  ```python
  me = obj.data
  me.transform(obj.matrix_world)        # or matrix_basis to keep parent transform
  obj.matrix_world.identity()
  ```
  After applying, **assert `obj.scale == (1,1,1)`**.
- **Units / scale.** Default Metric = 1 BU = 1 m; glTF is meters and **+Y up**
  (the exporter's `+Y Up` handles the axis swap — leave it on, §5). Model the hero
  at ~0.1–2 m so import/physics/bevel widths behave; avoid mm/giant scales.
- **Origin placement.** It becomes the engine pivot (bevy spin) and the sprite
  rotation center — usually geometric center for a turntable/spun core:
  `bpy.ops.object.origin_set(type='ORIGIN_GEOMETRY')` (or `ORIGIN_CENTER_OF_MASS`).

### Non-destructive modifier workflow
- **Keep modifiers live while iterating; bake on export.** The glTF exporter's
  **Apply Modifiers** (`export_apply=True`, §5) evaluates the stack into the exported
  mesh. For deterministic Python output, apply explicitly:
  `bpy.ops.object.modifier_apply(modifier="Bevel")`, or evaluate the depsgraph (§1).
- **Useful modifiers:** Subdivision Surface, Bevel, Solidify, Mirror, Boolean, Array,
  **Weighted Normal** (fix shading on beveled hard surfaces), **Decimate** (poly
  reduction: `Collapse`/`Planar`/`Un-Subdivide`).
- **Order matters** (top→bottom, each feeds the next). Solid hard-surface order:
  1. **Mirror** (symmetry first) → 2. **Array/Boolean** (build/cut) →
  3. **Solidify** (thickness before rounding) → 4. **Bevel** (round resolved edges) →
  5. **Subdivision Surface** (Bevel-before-Subsurf keeps edges crisp) →
  6. **Weighted Normal** (clean shading) → 7. **Triangulate** (last, optional, for
  export determinism). Wrong order = e.g. Subsurf-then-Mirror leaves a center seam.
- **Shade smooth/flat & normals.** `bpy.ops.object.shade_smooth()`/`shade_flat()`.
  **Auto Smooth is no longer a mesh checkbox** — since **Blender 4.1** it's the
  **"Smooth by Angle" modifier** (`bpy.ops.object.shade_auto_smooth()` adds it).
  Custom split normals no longer require enabling Auto Smooth. Typical hero recipe:
  Shade Smooth → Smooth by Angle (~30–45°) → Weighted Normal, then export normals.

### Geometry Nodes (procedural / parametric)
- **When GN is right:** parametric forms tuned by a few sliders (counts, radii, twist,
  instanced shards/rings, scatter) — better than hand-mesh when the form is defined by
  parameters the agent will sweep. A GN modifier is a node-graph (usually top of stack)
  taking geometry in, geometry out.
- **Realize before export — critical.** GN often outputs **instances**; the exporter's
  GN-instance export is experimental and `Apply Modifiers` on an instance-producing
  tree can export **empty** geometry. End the tree with a **Realize Instances** node
  before applying/exporting. To bake to a plain mesh in Python:
  ```python
  deps = bpy.context.evaluated_depsgraph_get()
  eval_obj = obj.evaluated_get(deps)
  new_mesh = bpy.data.meshes.new_from_object(eval_obj)   # realized, modifiers baked
  ```
  (Treat specific 5.1 GN node *names* as needing a quick check; the realize-before-
  export rule holds across 4.x→5.x.)

### Hard-surface & stylized (neon / Big Sur) form
- **Bevels are how edges catch light.** A sharp 90° edge reads as a black line and
  gives a rim/neon highlight nothing to grab. A small consistent bevel (2–3 segments,
  or 1 chamfer + Weighted Normal) creates the soft specular edge-glow that defines the
  Big-Sur look — the **highest-payoff single technique** for the aesthetic.
- **Weighted Normal** after beveling fixes the dark/uneven shading bevels cause —
  near-mandatory for clean stylized hard surfaces.
- **Subdivision-ready cage:** low-poly mostly-quad cage + support/holding edge loops
  (or edge crease) near corners you want crisp, then Subsurf. No support loops =
  mushy/over-rounded (that's the smoothness knob).
- **Boolean cleanup:** Booleans leave n-gons; add a guidance edge along the intended
  seam, cut, then bevel/clean and n-gon-purge before export.

### Poly budget / optimization
- **Budgets (desktop real-time):** an abstract hero core is comfortable at
  **~5k–30k tris** — enough for a clean silhouette + beveled highlights, cheap for an
  effects context. The **bevy real-time** path sets the ceiling; offline sprite
  rendering tolerates more.
- **Decimate vs retopo vs LOD:** Decimate = fast, automatic, ugly flow, breaks loops —
  fine for a static non-deforming hero, bad for animated/normal-mapped. Retopo = clean,
  expensive (skip for a one-angle static core). LOD = high LOD0 + reduced LOD1 if bevy
  swaps by distance. For this project, **Decimate (Collapse/Planar) on a static core**
  is usually pragmatic; retopo only if shading artifacts appear.

### Scene & file organization
- **Collections** group objects and scope export (Selected / Visible / Active
  Collection). Pattern: one collection per shippable asset → export per-collection.
- **Deterministic naming.** Name *both* object and mesh datablock (separate IDs):
  `obj.name = "hero_core"; obj.data.name = "hero_core_mesh"`. Stable names make re-runs
  idempotent and engine-side lookups predictable. Avoid `.001` suffixes.
- **Datablock / user-count model.** Blender ref-counts datablocks; `block.users` =
  refs, `block.use_fake_user = True` keeps a 0-user block alive. **Orphans** (0 users)
  drop on save/reload. Purge after procedural churn:
  ```python
  bpy.data.orphans_purge(do_local_ids=True, do_linked_ids=True, do_recursive=True)
  ```
  `do_recursive=True` cascades. Run before saving/exporting so the `.blend`/export
  don't carry junk meshes/materials.
- **Link vs append:** Append copies data in (independent, editable, heavier); Link
  references an external `.blend` (synced, lighter, read-only locally). Self-contained
  hero source → append/local is simpler.
- **Version control:** `.blend` files are **binary** — git can't diff/merge them and
  they bloat history. So: save incrementally (`hero_core_v003.blend`) for rollback,
  and **treat the generating Python script as the diffable "source"** kept in git,
  with the exported `.glb` + a render as the reviewable artifacts. (The repo already
  commits `hero_core.glb` + `hero.rs`; keep the build script alongside.)

### Pitfalls an automated agent hits
- Forgetting to **apply scale** → wrong bevel width, broken normals, warped glTF.
- **N-gons exported raw** → unpredictable triangulation, banded shading.
- **GN instances not realized** → empty/missing static mesh in glTF.
- **Relying on UI/selection state** → set context explicitly or use the data API.
- **Auto-Smooth muscle memory** → it's the **Smooth by Angle modifier** (4.1+).
- **Origin/axis mismatch** → wrong pivot in bevy / wrong rotation in the turntable.
- **Orphan buildup** from re-runs → recursive `orphans_purge()` + deterministic names.

---

## 3. Materials & shading

Two output paths, different rules: **(A) EEVEE → PNG sprite sheets** (you control the
render; glow/tonemap happen in Blender) and **(B) glTF → bevy** (only a PBR subset
survives; glow is bevy's job). `[v4.0]`/`[v4.2]`/`[v5.0]` mark behavior/API changes.

### Principled BSDF — the inputs that matter
Since **4.0** it's "Principled v2" (OpenPBR-based) `[v4.0]` — the right default for
neon/glass/metal/plastic and the *only* surface shader glTF fully understands. Access
inputs **by socket name, never index** (v2 reordered; index 16 is a dead no-op).

| Socket (5.x) | Range / default | Notes |
|---|---|---|
| `Base Color` | RGB, grey | Diffuse + metal + transmission tint. **sRGB**. |
| `Metallic` | 0–1, 0 | Binary in practice: 0 = dielectric, 1 = metal. |
| `Roughness` | 0–1, 0.5 | 0 = mirror, 1 = diffuse. **Non-Color** texture. |
| `IOR` | ~1.0–4.0, **1.5** | Dielectric specular + refraction. 1.5 ≈ glass/plastic. |
| `Alpha` | 0–1, 1 | Cutout/blend transparency. *Not* Transmission. |
| `Normal` | vector | From a Normal Map node (tangent space). |
| `Emission Color` | RGB, black | Renamed `[v4.0]` (was "Emission"). **sRGB**. |
| `Emission Strength` | 0–∞, **1.0** | 1.0 = shows exactly Emission Color (shadeless). >1 to glow. |
| `Coat Weight/Roughness/IOR/Tint/Normal` | weight 0–1 | Clearcoat (was "Clearcoat*"). Great for glassy Big-Sur lacquer. |
| `Sheen Weight/Roughness/Tint` | weight 0–1 | Fuzz/edge glow; subtle rim on cores. |
| `Specular IOR Level` (0.5 = neutral) / `Specular Tint` | 0–1 | Was "Specular" scalar. |
| `Transmission Weight` | 0–1, 0 | Glass/liquid (below). Was "Transmission". |
| Subsurface, Specular Anisotropic, Thin Film | — | **Several are Cycles-only** — ignored/approximated in EEVEE and **don't export to glTF**. |

**Metallic vs dielectric:** pick one. Metal = `Metallic 1`, color in Base Color, no
diffuse/transmission. Dielectric (plastic/glass/neon shell) = `Metallic 0`, specular
from `IOR` (1.45–1.55). Don't combine high Metallic with Transmission.

### EEVEE (Next) vs old EEVEE vs Cycles
**EEVEE Next** replaced legacy EEVEE in **4.2 LTS** `[v4.2]` (it *is* "EEVEE" now;
in 5.0+ the engine id is back to `BLENDER_EEVEE`). Changes: screen-space ray tracing
for every BSDF, Virtual Shadow Maps, unlimited lights, real-time displacement,
viewport motion blur. Renames `[v4.2]`: "Screen-Space Refraction" → **"Raytraced
Transmission"**, Blend Mode → **Render Method** (Alpha Blend → "Blended"; Alpha Clip
via a Math `Greater Than` node).

When to use which **here**:
- **EEVEE (sprite sheets):** default. Fast, real-time-ish, matches what bevy does.
  Enable **Ray Tracing** in Render Properties for good reflections/transmission.
- **Cycles:** only for features EEVEE lacks (true SSS, accurate caustics, anisotropy,
  thin-film) or for **baking** procedurals to textures. ⚠️ **Not available on this
  flatpak** (§0) — needs a Cycles-enabled build.

EEVEE diverges from Cycles: screen-space methods miss off-screen reflections/refraction;
SSS is approximate; Cycles-only inputs ignored. **Render the look in the engine you'll
ship** — don't assume a Cycles-tuned material matches EEVEE.

### Emission / neon glow
**Use the Principled BSDF's `Emission Color` + `Emission Strength`** for neon cores —
no separate Emission shader needed. Strength is unbounded; `1.0` = shadeless; for glow
push **2–10+** so pixels exceed 1.0 and the glare/bloom catches them. Under AgX, very
high strengths desaturate toward white — use **Standard** view transform (below) to
keep neon saturated on the PNG path.

**Bloom is gone from EEVEE** `[v4.2]` (verified: `eevee.use_bloom` absent on this
build). Glow on the sprite path comes only from the **Compositor → Glare node**:
- Add `Render Layers → Glare → Composite`. Glare **Type**: **Bloom** (fast) or
  **Fog Glow** (softer, closest to old EEVEE bloom). Key controls: **Threshold**
  (>1.0 so only emissive/HDR pixels glow), **Size**, **Strength/Mix**, **Smoothness**.
  Viewport preview: Viewport Shading → Compositor → **Always**.
- ⚠️ **5.x compositor:** most node settings were **inlined as input sockets** `[v5.0]`,
  so `glare_type`/`size`/`threshold` may be `node.inputs["..."].default_value` rather
  than properties. **Introspect** (`[s.name for s in node.inputs]`) before hard-coding.
- **For the glTF path, do NOT bake glow into the material** — glTF carries
  `emissiveFactor` + `KHR_materials_emissive_strength`; **bevy** renders the bloom (§5).
  Glare-node glow is purely for the PNG sprite path.

### Glass / transmission
- **EEVEE:** `Transmission Weight = 1`, `Roughness 0` (clear) / higher (frosted),
  `IOR ≈ 1.45–1.5`. Enable **Raytraced Transmission** per-material *and* Ray Tracing in
  render settings `[v4.2]`. Screen-space limits: no refraction of off-screen geometry,
  and transmissive-behind-transmissive generally fails (fine for a stylized accent).
- **Cycles:** real refraction/caustics, no screen-space limits; slower (and
  unavailable on this flatpak).
- **glTF:** `Transmission Weight > 0` → `KHR_materials_transmission`; add Volume
  Absorption for `KHR_materials_volume`. Transmission ≠ Alpha (glass = Transmission +
  **Opaque** blend, full specular; alpha = missing geometry). **bevy support for
  transmission is limited** — if it doesn't render, fake glass with low-alpha +
  high-specular or a dedicated shader.

### Building materials via Python
See the `new_principled`/`setp` helpers in **§1**. Rules: sockets by name (not index);
emission is `Emission Color`; link by name
(`nt.links.new(a.outputs["BSDF"], b.inputs["Surface"])`); reuse a shared
`ShaderNodeTree` group for variants; name deterministically. Texture color spaces:
`image.colorspace_settings.name = "sRGB"` for color/emission, `"Non-Color"` for
roughness/metallic/normal/AO.

**Compositor node-tree API changed in 5.0** `[v5.0]` — `scene.node_tree` removed,
`scene.use_nodes` deprecated. New way:
```python
tree = bpy.data.node_groups.new("Comp", "CompositorNodeTree")
scene.compositing_node_group = tree
rl    = tree.nodes.new("CompositorNodeRLayers")
glare = tree.nodes.new("CompositorNodeGlare")
# 5.x: glare params may be input sockets — introspect, then e.g.
# glare.inputs["Threshold"].default_value = 1.0   (verify the socket exists)
```
File Output node also changed in 5.0 (`base_path`/`file_slots` → `directory`/
`file_name`/`file_output_items`). **Branch on `bpy.app.version` for compositor scripting.**

### Color management
- **Texture color spaces (non-negotiable):** Base/Emission Color = **sRGB**;
  Roughness/Metallic/Normal/AO/masks = **Non-Color**. Wrong space on a data map is the
  most common silent material bug; the glTF exporter *requires* Non-Color on those.
- **View transform:** default **AgX** `[v4.0]` (filmic rolloff, desaturates emissive
  toward white). **Standard** = plain sRGB, no tonemapping; **Khronos PBR Neutral** ≈
  how a real-time engine displays colors.
- **For literal saturated neon on the PNG path use `Standard`** (or PBR Neutral) so
  output equals authored sRGB. AgX mutes/shifts it. Trade-off: Standard clips HDR
  highlights hard, so tune emission strength under the transform you'll actually render.
- **View transform bakes into 8-bit outputs** (PNG/JPEG): sprite-sheet PNGs *are*
  affected by AgX vs Standard. EXR/HDR ignore it (raw linear). For the **glTF path**,
  view transform is irrelevant — only raw material values export; bevy tonemaps.

### Texturing & baking for export
- **UV unwrap is required for any textured glTF export** — every exported mesh needs
  ≥1 UV map; normal maps also need a Tangent node bound to the *same* UV. No UVs →
  textures don't map in bevy.
- **Procedural shaders do NOT export to glTF** — bake them to image textures first
  (Base Color, Roughness, Emission, Normal) and rebuild a simple Principled material
  wired to the baked images. ⚠️ **Baking needs Cycles** — unavailable on this flatpak
  (§0); either install a Cycles build, or author with image textures from the start /
  keep glTF materials to solid factors + emission.
- **glTF channel packing:** metal/rough as one image (**Roughness=G, Metallic=B**,
  optional **AO=R**), all **Non-Color**, PNG/JPEG only.

### Common material pitfalls
- Setting inputs **by index**; using pre-4.0 `"Emission"` → silent no-op.
- Expecting an EEVEE **Bloom** toggle → use Glare (PNG) or bevy bloom (glTF).
- Scripting the compositor with `scene.node_tree`/`use_nodes` on 5.x → removed.
- Hard-coding **Glare node properties** on 5.x → many are now input sockets.
- Forgetting **Raytraced Transmission** + Ray Tracing for EEVEE glass.
- Wrong **color space** on data maps; authoring with **Cycles-only** inputs.
- Confusing **Transmission with Alpha**; relying on **procedural nodes** for glTF.
- Assuming the **view transform doesn't affect PNGs**.

---

## 4. Lighting, camera & rendering

Recipe for the EEVEE sprite path. **Verify every render by reading the PNG back.**

> **Engine id (version trap):** 4.2–4.5 = `'BLENDER_EEVEE_NEXT'`; **5.0+ =
> `'BLENDER_EEVEE'`** (this build). Set it defensively:
> ```python
> for eng in ('BLENDER_EEVEE','BLENDER_EEVEE_NEXT'):
>     try: bpy.context.scene.render.engine = eng; break
>     except TypeError: pass
> ```

### Lighting fundamentals (hero / product shots)
Three-point: **key** (~45° off-axis front, high), **fill** (opposite, weaker, kills
harsh shadow), **rim/back** (behind, separates subject — your neon edge glow). Use
**Area lights** — their **Size** is the only thing controlling softness.
- **Power = Watts** (Area/Point/Spot; default 10 W is tiny for a hero). **Sun** is
  W/m² irradiance, ignores distance.
- **Size → softness:** bigger Area = softer shadows/specular but *dimmer* (scale power
  up as you grow it). Small = hard/studio; large = soft/wraparound.
- **Ratios, not absolutes:** fill ≈ ⅓–½ of key (1:2–1:3). Rim can be brighter than key
  for strong edge glow; keep it saturated (cyan/magenta) for neon.
- **Neon edge:** bright, fairly small rim behind/above aimed at camera + an emission
  material on the hero; bloom (Glare node, §3, + the wallpaper's `bloom.frag`) sells it.

```python
import bpy
from mathutils import Vector

def add_area(name, loc, size, power, color=(1,1,1)):
    ld = bpy.data.lights.new(name, 'AREA'); ld.size = size; ld.energy = power; ld.color = color
    ob = bpy.data.objects.new(name, ld); ob.location = loc
    bpy.context.collection.objects.link(ob); return ob

target = Vector((0,0,0.5))
key  = add_area("Key",  ( 3.0,-3.0,3.5), 2.0, 1200)
fill = add_area("Fill", (-3.5,-2.0,1.5), 3.0,  400)               # big+soft, ~⅓ key
rim  = add_area("Rim",  (-1.5, 3.5,3.0), 1.0, 1500, (0.4,0.8,1.0))# bright cyan, behind
for L in (key, fill, rim):                                        # aim each at target
    L.rotation_euler = (target - L.location).to_track_quat('-Z','Y').to_euler()
```

### World / environment
Ambient fill + reflections. For a clean *dark* Big-Sur look: near-black background
that still throws colored reflections on the glossy hero.
```python
w = bpy.context.scene.world or bpy.data.worlds.new("World")
bpy.context.scene.world = w; w.use_nodes = True
bg = w.node_tree.nodes.get("Background")
bg.inputs["Color"].default_value = (0.01,0.01,0.015,1.0)
bg.inputs["Strength"].default_value = 0.3          # 0 = pure black, no reflections
```
HDRI for best reflections/fill: add `ShaderNodeTexEnvironment`, load an `.hdr` **under
$HOME** (sandbox), link to the Background `Color`. **Dark bg but keep HDRI
reflections:** keep `film_transparent=True` (the visible bg is empty, HDRI still
lights/reflects), or a Light Path `Is Camera Ray` mix (black to camera, HDRI to
reflections). Address sockets **by name** — 5.0 reworked node internals; the basic
`nodes`/`links.new(out, in)` pattern still works for the world tree.

### Camera setup via Python
Prefer **perspective, longish lens** (`cam.data.lens = 70–100`) to flatten
distortion, OR **orthographic** (`cam.data.type='ORTHO'` + `ortho_scale`) — ideal for
turntable sprites since the silhouette size never breathes with rotation.

*Aim — look-at math (deterministic, best for headless turntables):*
```python
def aim(cam_obj, target):
    cam_obj.rotation_euler = (target - cam_obj.location).to_track_quat('-Z','Y').to_euler()
```
*Or a Track-To constraint* (`c = cam.constraints.new('TRACK_TO'); c.target = empty;
c.track_axis='TRACK_NEGATIVE_Z'; c.up_axis='UP_Y'` — **track_axis and up_axis must
differ** or it silently dies).

*Framing (fit camera to object)* — `Camera.camera_fit_coords(depsgraph, coords)`
returns the location + ortho_scale that frame a point set; feed it the evaluated
bbox corners. **Aim first, then fit** (it moves along the current view axis):
```python
dg = bpy.context.evaluated_depsgraph_get()
ob = bpy.data.objects["Hero"].evaluated_get(dg); mw = ob.matrix_world
coords = [c for v in (mw @ Vector(corner) for corner in ob.bound_box) for c in v]
loc, scale = cam_obj.data.camera_fit_coords(dg, coords)
cam_obj.location = loc
if cam_obj.data.type == 'ORTHO': cam_obj.data.ortho_scale = scale * 1.1   # ~10% margin
```
Skip DOF for sprite sheets — you want crisp silhouettes. (Verify the
`camera_fit_coords` return tuple on the actual build.)

### Render settings (EEVEE) + transparent background
```python
sc = bpy.context.scene; r = sc.render
sc.eevee.taa_render_samples = 64        # final; 8–16 for fast proofs
r.resolution_x, r.resolution_y = 1024, 1024
r.resolution_percentage = 100           # 25–50 for proofs
r.film_transparent = True               # THE key line: world bg → alpha 0
r.image_settings.file_format = 'PNG'
r.image_settings.color_mode  = 'RGBA'   # NOT 'RGB' — RGB silently drops alpha
r.image_settings.color_depth = '8'      # '16' for smoother glow gradients
```
**Color management ↔ exposure (matters for neon):** `view_settings.view_transform`
defaults to **AgX** (mutes emissive) — use `'Standard'` for punchy literal neon.
`view_settings.exposure`/`.look` shift brightness before the file is written (a dark
proof is often exposure/view-transform, not lighting). PNG **bakes in** the view
transform (EXR is raw linear) — so the PNG is exactly what the wallpaper will show.

> EEVEE Next transparency: per-material **Render Method** (`Dithered` default /
> `Blended`) only matters if the hero itself is see-through; `film_transparent`
> handles the canvas alpha regardless. Confirm by reading a corner pixel's alpha == 0.

### Turntable rendering
Keep **lights, world, camera fixed**; spin the **object** (reflections/lighting then
change correctly as it turns). Render N stills, one PNG each.
```python
import bpy, math, os
N = 16; OUT = os.path.expanduser("~/nimbus_renders/turntable"); os.makedirs(OUT, exist_ok=True)
ob = bpy.data.objects["Hero"]; ob.rotation_mode = 'XYZ'; base = ob.rotation_euler.z
for i in range(N):
    ob.rotation_euler.z = base + 2*math.pi*i/N
    bpy.context.view_layer.update()                      # apply transform before render
    bpy.context.scene.render.filepath = os.path.join(OUT, f"frame_{i:02d}.png")
    bpy.ops.render.render(write_still=True)              # blocking; writes the PNG
```
**Assemble the atlas with Pillow** (Blender has no native packer; separate step):
```python
from PIL import Image; import math, os
frames = [Image.open(os.path.join(OUT, f"frame_{i:02d}.png")).convert("RGBA") for i in range(N)]
cw, ch = frames[0].size; cols = int(math.ceil(math.sqrt(N))); rows = int(math.ceil(N/cols))
sheet = Image.new("RGBA", (cols*cw, rows*ch), (0,0,0,0))      # transparent canvas
for i, fr in enumerate(frames):
    sheet.paste(fr, ((i%cols)*cw, (i//cols)*ch), fr)         # 3rd arg = mask keeps alpha
sheet.save(os.path.expanduser("~/nimbus_renders/hero_turntable_4x4.png"))
```
Shader UV math: frame `i` at column `i%cols`, row `i//cols`; cell size `(1/cols,1/rows)`;
cell origin `(col/cols, row/rows)`. Keep **all cells identical size** (ortho or fixed
framing) and pad 1–2 px transparent margin if the shader does bilinear sampling.

### Rendering from Python (headless) — path gotchas
- Still → `render.filepath = "/abs/path.png"; bpy.ops.render.render(write_still=True)`.
  Animation (Blender numbers frames) → end the path with `####` + `render(animation=True)`.
- **`//` relative paths** resolve to the saved `.blend` dir; unsaved (typical over the
  bridge) → unreliable. **Use absolute paths.**
- **Sandbox:** render under **`$HOME`**, not `/tmp`; `os.makedirs(..., exist_ok=True)`
  first. **Read the file back and check non-zero size** — "render returned" ≠ "file written."

### Performance & verification
- EEVEE uses **TAA**: quality ∝ `taa_render_samples`. **Proof 8–16, final 32–64.**
  Drop `resolution_percentage` to 25–50 for proofs.
- Verification loop: (1) `resolution_percentage=25`, `taa_render_samples=8`, render
  frame 0 to `~/nimbus_renders/proof.png`; (2) Read it back — file non-zero, object
  centered/in-frame, key/fill/rim + neon edge visible (not crushed/blown), a bg corner
  pixel alpha == 0; (3) dark proof → suspect **AgX** (try `'Standard'`)/exposure before
  adding light; bg not transparent → check `film_transparent=True` **and**
  `color_mode='RGBA'`; (4) only then run the full 16-frame loop + atlas.

---

## 5. glTF export for real-time / bevy

Exporting stylized glowing hero meshes as **GLB** that loads correctly in **bevy 0.18**
(wgpu/Vulkan, PBR + emissive + bloom). The single most expensive gotcha is the
coordinate contract (§5.1) — **bevy 0.18 does not convert glTF coordinates by default**.

### 5.1 Coordinate systems & scale
- **Axes.** Blender is Z-up; glTF is Y-up. The exporter's **`export_yup=True`**
  (default) bakes the Z→Y rotation so the GLB is spec-correct Y-up. **Leave it on** —
  turning it off tips the model 90° in every compliant viewer.
- **Apply object transforms first** (§2). Unapplied scale → "100× too big/small";
  unapplied rotation rides on the Y-up conversion → surprise tilts. Either
  *Object ▸ Apply ▸ All Transforms* (or `bpy.ops.object.transform_apply(...)`) **and**
  `export_apply=True` (which applies *modifiers*, not object transforms — you want both).
- **Unit scale.** glTF unit = 1 m; keep Blender Unit Scale = 1.0 and model in meters.
  A 100×-off model is almost always unapplied scale or a cm/mm unit setup, not the
  exporter.
- **bevy 0.18 orientation contract — read this.** bevy is Y-up/-Z-forward; glTF is
  Y-up/+Z-forward. **In 0.18 glTF coordinate conversion is *disabled by default***
  (`GltfConvertCoordinates::default()` is all-false): a Y-up GLB loads upright
  (geometry correct) but faces the opposite way. Fix on the **bevy side** — either a
  180°-Y spawn `Transform`, or opt into conversion:
  ```rust
  use bevy::gltf::{GltfPlugin, convert_coordinates::GltfConvertCoordinates};
  App::new().add_plugins(DefaultPlugins.set(GltfPlugin {
      convert_coordinates: GltfConvertCoordinates { rotate_scene_entity: true, ..default() },
      ..default() }));
  ```
  ⚠️ **0.17→0.18 migration:** the old `GltfPlugin::use_model_forward_direction: bool`
  was **removed** → `GltfConvertCoordinates { rotate_scene_entity, rotate_meshes }`
  (default OFF). Upstream flags it **experimental** — verify against your pinned 0.18.x.
  **Rule:** always export `export_yup=True` (spec-correct); decide orientation in bevy.
  Never pre-rotate in Blender to compensate.

### 5.2 Which Principled BSDF features survive glTF
The exporter understands the **Principled BSDF** + a few glue nodes; each channel must
be a direct value or an *Image Texture → [Mapping → UV]* chain.

| Principled → glTF | Survives? | Notes |
|---|---|---|
| Base Color (+ texture) | ✅ | `baseColorFactor`/`baseColorTexture` |
| Metallic, Roughness | ✅ | One `metallicRoughnessTexture` (G=rough, B=metal); author as ORM |
| Normal (via Normal Map node) | ✅ | Tangent-space; **needs UVs + exported tangents** (§5.5) |
| Emission Color + Strength | ✅ | `emissiveFactor` + **`KHR_materials_emissive_strength`** (§5.3) |
| Alpha / Blend Mode | ✅ | `alphaMode` OPAQUE/MASK/BLEND + `alphaCutoff` |
| Occlusion (AO) | ✅* | Only via the **glTF Material Output** node's Occlusion input (R; pack into ORM) |
| IOR | ✅ | `KHR_materials_ior` |
| Transmission, Specular, Sheen, Coat, Volume | ✅* | KHR_materials_*; several need the glTF Material Output node; **bevy support varies** |

**Silently does NOT export** (renders flat/grey, no error): **procedural textures**
(Noise/Voronoi/Musgrave/Wave/Magic/Gradient/Brick/Checker + node math),
**displacement** (apply as a modifier + `export_apply`, or bake to normal), most
**non-Principled** nodes (Toon/Glass/standalone BSDFs/Mix Shader trees), OSL, light
paths. **Rule: bake every procedural channel to an Image Texture first** (⚠️ baking =
Cycles, unavailable on this flatpak — §0/§3). Vertex colors export only if explicitly
enabled (§5.5).

### 5.3 Emissive / neon (the glow)
1. **Blender:** Principled `Emission Color` = hue, `Emission Strength > 1` (5–50). The
   exporter writes `emissiveFactor` (clamped ≤1) + **`KHR_materials_emissive_strength`**
   = your multiplier. Without that extension, glTF emissive caps at 1.0 and never blooms.
2. **bevy 0.18** reads `KHR_materials_emissive_strength` (since 0.12) and folds it into
   `StandardMaterial::emissive` (a `LinearRgba` that may exceed 1.0) — bright enough to
   bloom.
3. **Bloom needs an HDR camera + Bloom + tonemapping** — emission alone won't glow on
   an LDR camera:
   ```rust
   commands.spawn((Camera3d::default(), Camera { hdr: true, ..default() },
       Tonemapping::TonyMcMapface, Bloom::NATURAL));   // Bloom is bevy::post_process::bloom
   ```
   **Flat/no-halo emission** = (a) `hdr:false`, (b) no `Bloom`, or (c) strength ≤1. Fix
   by raising **emissive strength in Blender**, not bloom intensity.

### 5.4 GLB vs glTF+bin, packing, compression
- **Use `export_format='GLB'`** — one self-contained binary; best for a single hero
  asset, no missing-texture bugs. `'GLTF_SEPARATE'` is useful for inspecting the JSON
  (§5.8); avoid `'GLTF_EMBEDDED'` (base64, largest).
- **Texture format:** `export_image_format='AUTO'` (PNG with alpha / JPEG else). **Not
  `'WEBP'`** — bevy 0.18 does **not** support `EXT_texture_webp`.
- **Compression — verify before using:** **bevy 0.18 supports NO Draco / meshopt /
  basisu / GPU-instancing.** **Do NOT enable Draco** (`export_draco_mesh_compression_
  enable=False`) — a Draco GLB loads empty/fails in bevy. Hero meshes are small; ship
  uncompressed.
- **KHR extensions bevy 0.18 *reads*:** `KHR_lights_punctual`,
  `KHR_materials_emissive_strength`, `_ior`, `_unlit`, `_transmission`, `_volume`,
  `_specular`, `_clearcoat`, `_anisotropy`, `KHR_texture_transform` (base-color only).
  Several PBR ones need cargo features (`pbr_specular_textures`, etc.).

### 5.5 Mesh hygiene for export
- **`export_apply=True`** bakes modifiers (Subsurf/Mirror/Solidify/Array).
- **Triangulation:** glTF is triangles; prefer an explicit Triangulate modifier +
  `export_apply` so what you see ships (n-gons triangulate unpredictably).
- **Normals & custom split normals** define silhouette shading (`export_normals=True`);
  check for inverted faces (look like holes under backface culling).
- **Tangents** (`export_tangents=True`) are **required if you use a normal map** — else
  flat/garbled normal mapping.
- **UVs** (`export_texcoords=True`): every textured mesh needs ≥1 UV map (no UVs → grey).
- **Vertex colors:** `export_vertex_color='MATERIAL'` only if your bevy material samples
  `Mesh::ATTRIBUTE_COLOR`.
- **Merge** hero sub-parts sharing a material to cut draw calls; bevy spawns one entity
  per glTF mesh-primitive.

### 5.6 Recommended exporter settings (known-good Python)
Apply object transforms in-scene first, then:
```python
import bpy
# 1. Neutralize object transforms on the hero (node TRS → identity, origin-centered)
bpy.ops.object.select_all(action='DESELECT')
hero = bpy.data.objects["HeroCore"]
hero.select_set(True); bpy.context.view_layer.objects.active = hero
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)

# 2. Export
bpy.ops.export_scene.gltf(
    filepath="/home/corey/.../hero_core.glb",
    export_format='GLB',          # single self-contained binary
    use_selection=True,           # export only the hero (False = whole scene)
    export_apply=True,            # bake MODIFIERS (object transforms done above)
    export_yup=True,              # +Y up: spec-correct (default; keep ON)
    export_materials='EXPORT',    # PBR materials + KHR extensions
    export_image_format='AUTO',   # PNG/JPEG — NOT 'WEBP' (bevy can't read it)
    export_normals=True,
    export_tangents=True,         # REQUIRED if any normal map
    export_texcoords=True,        # UVs
    export_draco_mesh_compression_enable=False,  # bevy 0.18 has NO Draco
    export_extras=True,           # carry Blender custom properties into glTF 'extras'
    export_cameras=False,         # no Blender cameras in a hero asset
    export_lights=False,          # no Blender lights in a hero asset
    export_animations=False,      # True (+ skins/morphs) only if animated
)
import os; assert os.path.getsize("/home/corey/.../hero_core.glb") > 0
```
Defaults: `export_yup` True; `export_apply`/`use_selection`/`export_extras`/Draco all
False. Arg names are stable 4.x–5.1 except vertex colors (`export_vertex_color=
'MATERIAL'` vs legacy `export_colors`). `export_extras=True` is how Blender custom
properties reach bevy.

### 5.7 bevy-side specifics (0.18)
```rust
use bevy::prelude::*; use bevy::gltf::GltfAssetLabel;
fn spawn_hero(mut commands: Commands, assets: Res<AssetServer>) {
    commands.spawn((
        SceneRoot(assets.load(GltfAssetLabel::Scene(0).from_asset("models/hero_core.glb"))),
        Transform::from_xyz(0.0, 0.0, 0.0),
        // if conversion is OFF (0.18 default) and the hero faces away, either enable
        // GltfConvertCoordinates.rotate_scene_entity (§5.1) or rotate 180° about Y:
        // Transform::from_rotation(Quat::from_rotation_y(std::f32::consts::PI)),
    ));
}
```
- **`GltfAssetLabel`** labels: `Scene(usize)` (most common — preserves hierarchy),
  `Node`, `Mesh`, `Primitive{mesh,primitive}`, `Material`, `DefaultMaterial`, `Texture`,
  `Animation`, `Skin`, `MorphTarget`. Use `.from_asset(path)`.
- **Mesh-only / material-only** (to put a hero mesh on your own custom material):
  `assets.load(GltfAssetLabel::Primitive{mesh:0,primitive:0}.from_asset("..."))` paired
  with `Mesh3d(..)` + `MeshMaterial3d(custom)`. Or grab named items via `Assets<Gltf>`:
  `gltf.named_scenes`/`named_meshes`/`named_materials`.
- Materials import as `StandardMaterial`; `emissive` is `LinearRgba` carrying
  `emissiveStrength` (§5.3).
- **0.18 migration flags:** coordinate conversion changed (§5.1); extension handling is
  now the `GltfExtensionHandler` trait; Bloom lives in `bevy::post_process::bloom`.

### 5.8 Verification without a GUI
1. **Inspect the JSON** (export once `GLTF_SEPARATE`, or `gltf-transform` a GLB):
   `asset.version=="2.0"`; `extensionsUsed` includes
   `KHR_materials_emissive_strength` and **excludes** Draco/meshopt/WEBP;
   `materials[*].emissiveFactor` + strength present; primitives have `POSITION`,
   `NORMAL`, `TANGENT` (if normal-mapped), `TEXCOORD_0` (if textured); node `scale` is
   `[1,1,1]`. Quick:
   `python -c "import json;d=json.load(open('hero.gltf'));print(len(d['meshes']),len(d['materials']),d.get('extensionsUsed'))"`
2. **Khronos glTF-Validator** (authoritative): `gltf-validator hero_core.glb` (or
   `npx gltf-validator`) — zero errors = spec-correct.
3. **`gltf-transform inspect hero_core.glb`** (`npm i -g @gltf-transform/cli`) — scenes/
   meshes/materials/textures, vertex counts, extensions, texture sizes.
4. **bevy smoke test:** load `Scene(0)`, log `Assets<Gltf>` `scenes.len()`/
   `named_materials.keys()`. Untextured/grey → lost UVs or a procedural slipped through
   (§5.2); upside-down/backwards → §5.1; not glowing → §5.3 HDR/Bloom/strength triad.

---

## Sources

**Blender Python API & manual**
- bpy.ops (context override / temp_override / poll): https://docs.blender.org/api/current/bpy.ops.html
- bmesh (lifecycle, from_mesh/to_mesh/free): https://docs.blender.org/api/current/bmesh.html
- Depsgraph (evaluated_get / evaluated geometry): https://docs.blender.org/api/current/bpy.types.Depsgraph.html
- bpy.app (version gating): https://docs.blender.org/api/current/bpy.app.html
- Command-line args (`--background`, `--factory-startup`, `--python-exit-code`): https://docs.blender.org/manual/en/latest/advanced/command_line/arguments.html
- Avoiding bpy.ops for performance (data API vs ops): https://blendernotes.com/avoiding-bpy-ops-functions-for-better-performance-with-blenders-python-api/
- Linking objects to collections (modern pattern): https://b3d.interplanety.org/en/how-to-link-a-new-object-to-a-scene-in-blender-2-80-python-api/
- Coding materials with nodes & Python: https://behreajj.medium.com/coding-blender-materials-with-nodes-python-66d950c0bc02
- RenderSettings / AreaLight / Camera / SceneEEVEE / TrackToConstraint API: https://docs.blender.org/api/current/bpy.types.RenderSettings.html · …/bpy.types.AreaLight.html · …/bpy.types.Camera.html · …/bpy.types.SceneEEVEE.html · …/bpy.types.TrackToConstraint.html
- `camera_fit_coords` / object_utils: https://docs.blender.org/api/current/bpy_extras.object_utils.html
- orphans_purge: https://upbge.org/docs/latest/api/bpy.ops.outliner.html · datablock users/GC: https://surf-visualization.github.io/blender-course/api/data_block_users_and_gc/

**Version release notes**
- 4.0 Shading (Principled v2 socket renames): https://developer.blender.org/docs/release_notes/4.0/shading/
- 4.0 Color management (AgX default): https://developer.blender.org/docs/release_notes/4.0/color_management/
- 4.1 Modeling (Auto Smooth → Smooth by Angle modifier): https://developer.blender.org/docs/release_notes/4.1/modeling/
- 4.2 EEVEE Next (RT, VSM, Raytraced Transmission, Render Method, bloom removed): https://developer.blender.org/docs/release_notes/4.2/eevee/
- 4.2 Python API (material method renames): https://developer.blender.org/docs/release_notes/4.2/python_api/
- 5.0 Python API (`scene.node_tree`→`compositing_node_group`, File Output): https://developer.blender.org/docs/release_notes/5.0/python_api/
- 5.0 Compositor (node settings → input sockets): https://developer.blender.org/docs/release_notes/5.0/compositor/
- 5.0 EEVEE & Viewport (engine id `BLENDER_EEVEE`): https://developer.blender.org/docs/release_notes/5.0/eevee/

**Materials, color & EEVEE**
- Principled BSDF manual: https://docs.blender.org/manual/en/latest/render/shader_nodes/shader/principled.html
- Glare node: https://docs.blender.org/manual/en/latest/compositing/types/filter/glare.html
- Bloom removed → Glare + viewport Compositor: https://b3d.interplanety.org/en/enabling-the-bloom-effect-in-blender-4-2/
- View transform baked into PNG; Non-Color vs sRGB: https://docs.blender.org/manual/en/4.0/render/color_management.html
- AgX desaturates highlights; Standard/Raw for saturated palettes: https://cgcookie.com/posts/the-secret-to-rendering-vibrant-colors-with-agx-in-blender-is-the-raw-workflow
- EEVEE Next vs Cycles (when to use which): https://irendering.net/blender-cycles-vs-eevee-next-2026-when-to-use-real-time-when-to-use-ray-tracing/

**Lighting, rendering & atlas**
- Lights (power in W, size→softness, Sun irradiance): https://docs.blender.org/manual/en/latest/render/lights/light_object.html
- Three-point method: https://blog.yarsalabs.com/basics-of-lighting-setup-in-blender/
- Track-To constraint (axes must differ): https://docs.blender.org/manual/en/latest/animation/constraints/tracking/track_to.html
- look-at quat / camera turntable: https://harlepengren.com/take-a-spin-how-to-create-blender-python-camera-rotation/
- World nodes via Python: https://harlepengren.com/create-simple-world-nodes-with-the-blender-python-api/
- Film transparent panel: https://docs.blender.org/manual/en/latest/render/eevee/render_settings/film.html
- Cycles GPU rendering (compute_device_type/get_devices): https://docs.blender.org/manual/en/latest/render/cycles/gpu_rendering.html
- CLI `//` relative output, `####` frame numbering: https://www.mankier.com/1/blender
- Pillow grid/atlas (Image.new RGBA + paste mask): https://note.nkmk.me/en/python-pillow-concat-images/

**Modeling & topology**
- Modifiers introduction / Smooth by Angle: https://docs.blender.org/manual/en/latest/modeling/modifiers/introduction.html · …/modifiers/normals/smooth_by_angle.html
- Modifier order: https://braxtonwise.com/blender-modifier-order-modifier-stack/
- N-gons / clean topology: https://www.creativeshrimp.com/ngons-tutorial.html · https://hyper-casual.games/blog/clean-topology-blender
- Hard-surface modeling: https://hyper-casual.games/blog/hard-surface-modeling
- Poly budgets for game assets: https://3d-ace.com/blog/polygon-count-in-3d-modeling-for-game-assets/
- GN realize-instances export gotcha: https://github.com/KhronosGroup/glTF-Blender-IO/issues/1537 · …/issues/2317

**glTF & bevy**
- glTF 2.0 exporter manual (settings, material export, baking): https://docs.blender.org/manual/en/latest/addons/import_export/scene_gltf2.html
- `bpy.ops.export_scene.gltf` args: https://docs.blender.org/api/blender2.8/bpy.ops.export_scene.html
- Khronos: Blender glTF I/O PBR material extensions: https://www.khronos.org/blog/blender-gltf-i-o-support-for-gltf-pbr-material-extensions
- KHR_materials_emissive_strength spec: https://github.com/KhronosGroup/glTF/blob/main/extensions/2.0/Khronos/KHR_materials_emissive_strength/README.md
- bake-procedural-before-export: https://braincoke.fr/blog/2020/04/gl-tf-workflow-with-blender/
- bevy 0.18 release notes / 0.17→0.18 migration: https://bevy.org/news/bevy-0-18/ · https://bevy.org/learn/migration-guides/0-17-to-0-18/
- `bevy::gltf` (GltfAssetLabel, supported KHR extensions): https://docs.rs/bevy/latest/bevy/gltf/index.html
- `GltfPlugin` (convert_coordinates): https://docs.rs/bevy/latest/bevy/gltf/struct.GltfPlugin.html
- emissive bloom needs HDR/Bloom (#13133); compression status (#11350): https://github.com/bevyengine/bevy/issues/13133 · …/issues/11350
- Cheatbook HDR & Tonemapping / glTF: https://bevy-cheatbook.github.io/graphics/hdr-tonemap.html · https://bevy-cheatbook.github.io/3d/gltf.html

**blender-mcp**
- ahujasid/blender-mcp (TCP/timer exec, persistent state, caveats): https://github.com/ahujasid/blender-mcp

> **Provenance note.** The §0 "live-verified facts" were probed directly against the
> running flatpak (`bpy.app.version == (5,1,2)`): engine list `["BLENDER_EEVEE"]`
> (no Cycles/Workbench); `scene.node_tree` absent, `compositing_node_group` present;
> `material`/`world` `use_nodes` present and default-on; `eevee.use_bloom` absent;
> Principled `Emission Color`/`Emission Strength` present; MCP context
> `area==None`/`region==None`. Where these contradict generic web docs, **trust the
> probe** and re-verify on the actual build before relying on version-sensitive details
> (compositor Glare sockets, GN node names, `camera_fit_coords` return tuple).
