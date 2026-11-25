"""Define las especies y pinta su atlas de texturas pixeladas.

Por cada especie genera:
  - assets/textures/<Especie>_atlas.png   (una sola imagen con todas las caras, agrandada sin suavizado)
  - src/shared/Creatures/Data/<Especie>.json (piezas, articulaciones y el recorte del atlas de cada cara)

Uso: uv run --with pillow tools/creatures.py
Reglas de estilo: 4 px por stud en todas las caras; medidas en múltiplos de 0.25 stud;
luz arriba, sombra abajo, borde inferior oscuro, manchas de alto contraste.
"""

import json
import math
import random
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
PPS = 4  # píxeles por stud
UPSCALE = 8
ATLAS_W = 128

FACES = ["Front", "Back", "Left", "Right", "Top", "Bottom"]


def face_dims(size):
    sx, sy, sz = size
    return {
        "Front": (sx, sy),
        "Back": (sx, sy),
        "Left": (sz, sy),
        "Right": (sz, sy),
        "Top": (sx, sz),
        "Bottom": (sx, sz),
    }


def part(name, parent, size, joint, pivot=None, rot=None, ramp="body", neon=False, flat=False, pattern="mottled"):
    return {
        "name": name,
        "parent": parent,
        "size": list(size),
        "joint": list(joint),
        "pivot": list(pivot) if pivot else None,
        "rot": list(rot) if rot else None,
        "ramp": ramp,
        "neon": neon,
        "flat": flat,
        "pattern": pattern,
    }


def mirrored(p, out):
    for suffix, s in (("L", -1), ("R", 1)):
        q = dict(p)
        q["name"] = p["name"] + suffix
        q["joint"] = [p["joint"][0] * s, p["joint"][1], p["joint"][2]]
        if p["parent"].endswith("*"):
            q["parent"] = p["parent"][:-1] + suffix
        out.append(q)


# ------------------------------------------------------------------------------------------------
# Pintura de caras


def paint_face(rng, w, h, face, ramp_len, pattern):
    """Devuelve una grilla h x w de índices de tono (0 = más oscuro)."""
    base = ramp_len // 2
    g = [[base] * w for _ in range(h)]
    if pattern == "solid":
        pass
    else:
        # Manchas grandes claras y medias, con bordes irregulares.
        area = w * h
        for tone, count, rmax in ((base + 1, max(1, area // 22), 3 if area > 80 else 2), (base - 1, max(1, area // 26), 1)):
            for _ in range(count):
                cx, cy = rng.randrange(w), rng.randrange(h)
                r = rng.randint(1, rmax)
                for y in range(cy - r, cy + r + 1):
                    for x in range(cx - r, cx + r + 1):
                        if 0 <= x < w and 0 <= y < h and (x - cx) ** 2 + (y - cy) ** 2 <= r * r + rng.randint(-1, 1):
                            g[y][x] = tone
        for _ in range(max(1, area // 20)):
            g[rng.randrange(h)][rng.randrange(w)] = max(0, base - 2 + rng.randint(0, 1))
        for _ in range(max(1, area // 30)):
            g[rng.randrange(h)][rng.randrange(w)] = min(ramp_len - 1, base + 2)

    # Luz: arriba más claro, abajo más oscuro.
    if face == "Top":
        shift = lambda y: 1
    elif face == "Bottom":
        shift = lambda y: -2
    else:
        shift = lambda y: 1 if y < h * 0.25 else (-1 if y >= h * 0.7 else 0)
    for y in range(h):
        s = shift(y)
        for x in range(w):
            if s and rng.random() < 0.65:
                g[y][x] = max(0, min(ramp_len - 1, g[y][x] + s))
    if face not in ("Top", "Bottom") and h >= 3:
        for x in range(w):
            g[h - 1][x] = max(0, min(g[h - 1][x], base - 1) - (1 if rng.random() < 0.5 else 0))
    return g


def build_atlas(species):
    rng = random.Random(species["seed"])
    rects = []  # (part, face, w_px, h_px)
    for p in species["parts"]:
        if p["neon"] or p["flat"]:
            continue
        for face, (du, dv) in face_dims(p["size"]).items():
            w, h = max(1, round(du * PPS)), max(1, round(dv * PPS))
            rects.append((p, face, w, h))

    # Empaquetado en estantes, con 1 px de margen.
    rects.sort(key=lambda r: -r[3])
    x = y = shelf_h = 0
    placed = []
    for p, face, w, h in rects:
        if x + w + 1 > ATLAS_W:
            x, y, shelf_h = 0, y + shelf_h + 1, 0
        placed.append((p, face, w, h, x, y))
        x += w + 1
        shelf_h = max(shelf_h, h)
    atlas_h = y + shelf_h
    atlas_h = 1 << math.ceil(math.log2(max(atlas_h, 1)))

    img = Image.new("RGB", (ATLAS_W, atlas_h), tuple(species["ramps"]["dark"][1]))  # el borde que se cuele queda como contorno oscuro
    for p, face, w, h, ox, oy in placed:
        ramp = species["ramps"][p["ramp"]]
        grid = paint_face(rng, w, h, face, len(ramp), p.get("pattern", "mottled"))
        for gy in range(h):
            for gx in range(w):
                img.putpixel((ox + gx, oy + gy), tuple(ramp[grid[gy][gx]]))
        p.setdefault("faces", {})[face] = [ox / PPS, oy / PPS, w / PPS, h / PPS]

    out = ROOT / "assets" / "textures" / f"{species['name']}_atlas.png"
    out.parent.mkdir(parents=True, exist_ok=True)
    img.resize((ATLAS_W * UPSCALE, atlas_h * UPSCALE), Image.NEAREST).save(out)
    return out, (ATLAS_W / PPS, atlas_h / PPS)


def export(species):
    atlas_path, atlas_studs = build_atlas(species)
    data = {
        "name": species["name"],
        "atlasStuds": list(atlas_studs),
        "palette": {k: v[len(v) // 2] for k, v in species["ramps"].items()} | species.get("solids", {}),
        "parts": species["parts"],
    }
    out = ROOT / "src" / "shared" / "Creatures" / "Data" / f"{species['name']}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(data, indent=1), encoding="utf-8")
    print("ok", atlas_path.name, out.name)


# ------------------------------------------------------------------------------------------------
# Especies


def cuadrupedo():
    """Cuerpo bajo en dos bloques, cabeza grande y baja, patas cortas y gruesas."""
    P = []
    P.append(part("Rear", "Root", (3.5, 3, 3), (0, 3.25, 1.5)))
    P.append(part("Chest", "Rear", (3.75, 3.25, 3), (0, 0.125, -3)))
    P.append(part("Head", "Chest", (3, 2.5, 2.5), (0, -0.25, -1.5), pivot=(0, 0, 1.25)))
    P.append(part("Snout", "Head", (2, 1.5, 1), (0, -0.5, -1.25), pivot=(0, 0, 0.5), ramp="light"))
    P.append(part("Tail", "Rear", (1, 1, 1.25), (0, 0.75, 1.5), pivot=(0, 0, -0.625), rot=(-15, 0, 0)))
    mirrored(part("Nostril", "Snout", (0.25, 0.25, 0.1), (0.5, 0.25, -0.55), ramp="dark", flat=True), P)
    mirrored(part("Socket", "Head", (0.75, 0.5, 0.1), (0.875, 0.375, -1.3), ramp="dark", flat=True), P)
    mirrored(part("Eye", "Head", (0.25, 0.25, 0.1), (0.875, 0.375, -1.36), ramp="eye", neon=True), P)
    mirrored(part("Ear", "Head", (0.5, 0.5, 0.25), (1.125, 1.5, 0.75), ramp="dark"), P)
    mirrored(part("LegFront", "Chest", (1.25, 1.75, 1.25), (1.125, -1.375, -0.375), pivot=(0, 1.125, 0), ramp="leg"), P)
    mirrored(part("LegBack", "Rear", (1.25, 1.75, 1.25), (1.0, -1.25, 0.5), pivot=(0, 1.125, 0), ramp="leg"), P)
    return {
        "name": "Cuadrupedo",
        "seed": 3,
        "ramps": {
            "body": [(36, 38, 96), (58, 74, 150), (86, 116, 196), (124, 170, 230), (168, 212, 246)],
            "light": [(58, 74, 150), (86, 116, 196), (124, 170, 230), (158, 200, 242), (196, 230, 250)],
            "leg": [(30, 32, 80), (48, 60, 128), (72, 98, 176), (106, 148, 214), (146, 190, 238)],
            "dark": [(24, 26, 60), (34, 38, 84), (44, 50, 112), (56, 66, 136), (70, 92, 168)],
        },
        "solids": {"eye": (120, 240, 255)},
        "parts": P,
    }


if __name__ == "__main__":
    export(cuadrupedo())
