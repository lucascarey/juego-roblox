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


def part(name, parent, size, joint, pivot=None, rot=None, ramp="body", neon=False, flat=False, pattern="mottled", baby=1.0, skin=None):
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
        "babyScale": list(baby) if isinstance(baby, tuple) else baby,  # tamaño relativo en la cría (número o x,y,z)
        "skin": skin,
    }


def mirrored(p, out):
    for suffix, s in (("L", -1), ("R", 1)):
        q = dict(p)
        q["name"] = p["name"] + suffix
        q["joint"] = [p["joint"][0] * s, p["joint"][1], p["joint"][2]]
        if p["rot"]:
            q["rot"] = [p["rot"][0], p["rot"][1] * s, p["rot"][2] * s]
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
        for tone, count, rmax in ((base + 1, max(1, area // 26), 3 if area > 80 else 2), (base - 1, max(1, area // 40), 2)):
            for _ in range(count):
                cx, cy = rng.randrange(w), rng.randrange(h)
                r = rng.randint(1, rmax)
                for y in range(cy - r, cy + r + 1):
                    for x in range(cx - r, cx + r + 1):
                        if 0 <= x < w and 0 <= y < h and (x - cx) ** 2 + (y - cy) ** 2 <= r * r + rng.randint(-1, 1):
                            g[y][x] = tone
        for _ in range(max(1, area // 55)):
            g[rng.randrange(h)][rng.randrange(w)] = max(0, base - 2 + rng.randint(0, 1))
        for _ in range(max(1, area // 70)):
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


def material_map(rng, w, h, face, skin):
    """Igual que _materials, más grietas (material 3 = rampa "dark") si skin tiene cracks."""
    m = _materials(rng, w, h, face, skin)
    cracks = skin.get("cracks", 0)
    if cracks <= 0 or face == "Bottom":
        return m  # sin grietas no se usa el rng: los atlas viejos quedan idénticos
    # Grietas: líneas finas que avanzan casi rectas y a veces se quiebran.
    for _ in range(max(1, int(w * h * cracks / 30))):
        x, y = rng.randrange(w), rng.randrange(h)
        dx, dy = rng.choice(((1, 0), (0, 1), (1, 1), (1, -1)))
        for _ in range(rng.randint(3, 7)):
            if 0 <= x < w and 0 <= y < h:
                m[y][x] = 3
            if rng.random() < 0.35:
                dx, dy = rng.choice(((1, 0), (0, 1), (1, 1), (1, -1), (-1, 1)))
            x, y = x + dx, y + dy
    return m


def _materials(rng, w, h, face, skin):
    """Material de cada píxel: 0 = base, 1 = vientre claro, 2 = musgo.
    skin: belly = fracción inferior clara en las caras laterales, moss = densidad de musgo (0..1),
    mossTop = tapa superior casi toda de musgo."""
    m = [[0] * w for _ in range(h)]
    belly, moss = skin.get("belly", 0), skin.get("moss", 0)
    if face == "Bottom":
        return [[1 if belly else 0] * w for _ in range(h)]
    if face != "Top" and belly:
        # Límite rosa/blanco irregular, con gotas rosas que bajan.
        edge = h * (1 - belly)
        for x in range(w):
            b = int(edge + rng.choice((-1, 0, 0, 1)))
            if rng.random() < 0.25:
                b += rng.randint(1, 2)
            for y in range(max(0, b), h):
                m[y][x] = 1
    if face == "Top" and skin.get("mossTop"):
        for y in range(h):
            for x in range(w):
                if min(x, y, w - 1 - x, h - 1 - y) >= 1 or rng.random() < 0.5:
                    m[y][x] = 2
        return m
    if moss <= 0:
        return m
    # Manchas de musgo (más arriba que abajo) que chorrean hacia abajo.
    for _ in range(max(1, int(w * h * moss / 16))):
        cx = rng.randrange(w)
        cy = int(rng.random() ** (1.8 if face != "Top" else 1) * h)
        r = rng.choice((1, 2, 2, 3))
        for y in range(cy - r, cy + r + 1):
            for x in range(cx - r - 1, cx + r + 2):
                if 0 <= x < w and 0 <= y < h and abs(x - cx) + abs(y - cy) <= r + rng.randint(0, 1):
                    m[y][x] = 2
        if face != "Top":
            x, y = cx + rng.randint(-1, 1), cy + r
            for _ in range(rng.randint(1, 4)):
                if 0 <= x < w and 0 <= y < h:
                    m[y][x] = 2
                y += 1
    return m


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
        skin = p.get("skin")
        mats = material_map(rng, w, h, face, skin) if skin else None
        ramps = [
            ramp,
            species["ramps"].get("belly", ramp),
            species["ramps"].get("moss", ramp),
            species["ramps"].get("crack", ramp),
        ]
        for gy in range(h):
            for gx in range(w):
                r = ramps[mats[gy][gx]] if mats else ramp
                img.putpixel((ox + gx, oy + gy), tuple(r[grid[gy][gx]]))
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
        "babySize": species.get("babySize", 0.4),
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
    """Cuerpo en tres bloques (anca, vientre, pecho con joroba), cuello y cabeza bajos,
    mandíbula aparte, patas de tres segmentos, cola de tres y mechones en el lomo."""
    P = []
    # Cuerpo: el vientre es la raíz; el pecho adelante es el bloque más grande.
    P.append(part("Mid", "Root", (3.5, 3, 2.25), (0, 3.9, 0.5)))
    P.append(part("Rear", "Mid", (3.25, 2.75, 2.5), (0, -0.1, 1.125), pivot=(0, 0, -1.25), rot=(4, 0, 0)))
    P.append(part("Chest", "Mid", (3.75, 3.25, 2.5), (0, 0.15, -1.125), pivot=(0, 0, 1.25)))
    P.append(part("Hump", "Chest", (2.75, 0.75, 2), (0, 1.75, 0.25), ramp="light", baby=0.5))
    for name, parent, y in (("TuftA", "Mid", 1.6), ("TuftB", "Rear", 1.45), ("TuftC", "Chest", 2.2)):
        P.append(part(name, parent, (0.75, 0.5, 1), (0, y, 0), ramp="dark", baby=0.5))
    # Cabeza
    P.append(part("Neck", "Chest", (2.25, 2, 1.5), (0, 0.25, -1.25), pivot=(0, 0.25, 0.6), rot=(-14, 0, 0), baby=0.8))
    P.append(part("Head", "Neck", (3, 2.25, 2.5), (0, -0.1, -0.75), pivot=(0, 0.1, 1.1), rot=(8, 0, 0), baby=1.45))
    P.append(part("Snout", "Head", (2, 1.25, 1.25), (0, -0.35, -1.25), pivot=(0, 0, 0.6), ramp="light", baby=1.15))
    P.append(part("Jaw", "Head", (2.5, 0.75, 2), (0, -1.125, -0.4), pivot=(0, 0.375, 0.1), ramp="light", baby=1.3))
    mirrored(part("Nostril", "Snout", (0.25, 0.25, 0.1), (0.5, 0.2, -0.68), ramp="dark", flat=True, baby=1.3), P)
    mirrored(part("Socket", "Head", (0.75, 0.5, 0.1), (0.95, 0.55, -1.3), ramp="dark", flat=True, baby=1.6), P)
    mirrored(part("Eye", "Head", (0.25, 0.25, 0.1), (0.95, 0.55, -1.36), ramp="eye", neon=True, baby=1.7), P)
    mirrored(part("Ear", "Head", (0.5, 0.75, 0.5), (1.1, 1.4, 0.7), ramp="dark", baby=1.4), P)
    # Patas: muslo, caña y pata; las de adelante un poco más gruesas.
    mirrored(part("LegFU", "Chest", (1.5, 1.5, 1.5), (1.25, -1.3, -0.25), pivot=(0, 0.5, 0), rot=(-4, 0, 0), ramp="leg", baby=0.75), P)
    mirrored(part("LegFL", "LegFU*", (1.25, 1.25, 1.25), (0, -0.75, 0), pivot=(0, 0.5, 0), rot=(4, 0, 0), ramp="leg", baby=0.75), P)
    mirrored(part("PawF", "LegFL*", (1.5, 0.5, 1.75), (0, -0.625, -0.1), pivot=(0, 0.125, 0), ramp="dark", baby=0.9), P)
    mirrored(part("LegBU", "Rear", (1.5, 1.5, 1.5), (1.05, -1.2, 0.3), pivot=(0, 0.35, 0), rot=(6, 0, 0), ramp="leg", baby=0.75), P)
    mirrored(part("LegBL", "LegBU*", (1.25, 1.25, 1.25), (0, -0.75, 0), pivot=(0, 0.5, 0), rot=(-6, 0, 0), ramp="leg", baby=0.75), P)
    mirrored(part("PawB", "LegBL*", (1.5, 0.5, 1.75), (0, -0.625, -0.1), pivot=(0, 0.125, 0), ramp="dark", baby=0.9), P)
    # Cola en tres segmentos que se achican y se curvan hacia arriba.
    P.append(part("Tail1", "Rear", (1.25, 1.25, 1.25), (0, 0.6, 1.25), pivot=(0, 0, -0.5), rot=(-20, 0, 0), baby=0.8))
    P.append(part("Tail2", "Tail1", (1, 1, 1.25), (0, 0, 0.6), pivot=(0, 0, -0.5), rot=(-15, 0, 0), baby=0.75))
    P.append(part("Tail3", "Tail2", (0.75, 0.75, 1), (0, 0, 0.6), pivot=(0, 0, -0.4), rot=(-10, 0, 0), ramp="dark", baby=0.7))
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


MUSGO_RAMPS = {
    "body": [(196, 88, 116), (228, 118, 146), (244, 146, 170), (250, 172, 192), (254, 198, 212)],
    "belly": [(186, 160, 164), (214, 192, 196), (234, 216, 218), (244, 232, 233), (252, 246, 246)],
    "moss": [(62, 96, 22), (88, 124, 30), (112, 150, 40), (138, 174, 56), (164, 196, 78)],
    "horn": [(160, 70, 98), (190, 94, 122), (214, 118, 146), (230, 142, 166), (242, 166, 186)],
    "dark": [(120, 60, 90), (150, 80, 114), (176, 102, 138), (200, 126, 160), (220, 150, 180)],
}


def musgo():
    """Especie 1 (referencia de Lucas, 2026-11-25): cuerpo en dos bloques con lomos de musgo,
    cuello en dos segmentos, cabeza sin ojos con dos antenas, barba de musgo, patas con rodilla
    y cola larga en cuatro bloques. Rasgo de cría: cabeza y antenas grandes."""
    body = dict(belly=0.35, moss=0.4)
    P = []
    # El anca es la raíz (caderas); el pecho cuelga de ella para poder flexionar la columna.
    P.append(part("Rear", "Root", (4, 3.75, 3.5), (0, 3.9, 1.75), skin=body, baby=(1, 1, 0.8)))
    P.append(part("Chest", "Rear", (4, 3.75, 3.5), (0, 0, -1.75), pivot=(0, 0, 1.75), skin=body, baby=(1, 1, 0.8)))
    for name, parent in (("HumpB", "Rear"), ("HumpF", "Chest")):
        P.append(part(name, parent, (2.75, 0.75, 2.5), (0, 2.25, 0), skin=dict(moss=0.9, mossTop=True), baby=0.6))
    # Cuello en dos segmentos inclinados hacia adelante y arriba.
    P.append(part("Neck1", "Chest", (1.5, 1.5, 1.75), (0, 1.25, -1.5), pivot=(0, 0, 0.75), rot=(38, 0, 0), skin=dict(belly=0.3, moss=0.3), baby=0.85))
    P.append(part("Neck2", "Neck1", (1.25, 1.25, 1.75), (0, 0, -0.75), pivot=(0, 0, 0.75), rot=(8, 0, 0), skin=dict(belly=0.3, moss=0.25), baby=0.85))
    P.append(part("Head", "Neck2", (2.25, 1.75, 2.25), (0, 0, -0.75), pivot=(0, -0.2, 0.6), rot=(-46, 0, 0), skin=dict(belly=0.45, moss=0.15), baby=1.9))
    # Antenas: dos segmentos cada una, hacia atrás y un poco abiertas.
    mirrored(part("Ant1", "Head", (0.45, 1.1, 0.45), (0.55, 0.875, 0.35), pivot=(0, -0.5, 0), rot=(30, 0, -14), ramp="horn", pattern="solid", baby=1.7), P)
    mirrored(part("Ant2", "Ant1*", (0.4, 1, 0.4), (0, 0.5, 0), pivot=(0, -0.45, 0), rot=(8, 0, 0), ramp="horn", pattern="solid", baby=1.7), P)
    # Barba de musgo colgando del cuello.
    P.append(part("Beard1", "Neck1", (1.25, 1.5, 0.5), (0, -0.6, -0.4), pivot=(0, 0.7, 0), rot=(-38, 0, 0), ramp="moss", baby=0.7))
    P.append(part("Beard2", "Beard1", (1, 1.25, 0.4), (0, -0.7, 0), pivot=(0, 0.6, 0), ramp="moss", baby=0.7))
    # Patas: muslo y caña con rodilla.
    leg = dict(moss=0.35)
    low = dict(belly=0.55, moss=0.2)
    mirrored(part("LegFU", "Chest", (1.5, 1.75, 1.5), (1.25, -1.6, -0.5), pivot=(0, 0.75, 0), skin=leg, baby=0.8), P)
    mirrored(part("LegFL", "LegFU*", (1.5, 1.75, 1.5), (0, -0.875, 0), pivot=(0, 0.875, 0), skin=low, baby=0.8), P)
    mirrored(part("LegBU", "Rear", (1.5, 1.75, 1.5), (1.25, -1.6, 0.6), pivot=(0, 0.75, 0), skin=leg, baby=0.8), P)
    mirrored(part("LegBL", "LegBU*", (1.5, 1.75, 1.5), (0, -0.875, 0), pivot=(0, 0.875, 0), skin=low, baby=0.8), P)
    # Cola larga: cuatro bloques que se afinan.
    prev, plen = "Rear", 3.5
    for i, (w, h, l) in enumerate(((2, 1.75, 3.5), (1.5, 1.4, 3.25), (1.25, 1.1, 3), (1, 0.9, 2.75)), 1):
        P.append(part(f"Tail{i}", prev, (w, h, l), (0, 0.85 if i == 1 else 0, plen / 2), pivot=(0, 0, -l / 2),
                      rot=(-4 if i == 1 else 2, 0, 0), skin=dict(moss=0.4), baby=0.55 if i == 1 else 0.3))
        prev, plen = f"Tail{i}", l
    return {"name": "Musgo", "seed": 11, "babySize": 0.38, "ramps": MUSGO_RAMPS, "parts": P}


def huevo_musgo():
    """Huevo escalonado: capas en cruz (dos cajas cruzadas por capa) y tapa de musgo."""
    P = []
    prev, prev_h = "Root", 0
    layers = ((2.5, 0.75, 0, 1), (3.25, 1.5, 0.15, 0.6), (3, 1.25, 0.45, 0), (2.5, 0.75, 0.6, 0), (1.75, 0.5, 1, 0))
    for i, (w, h, moss, belly) in enumerate(layers, 1):
        skin = dict(belly=belly, moss=moss, mossTop=i >= 3)
        joint = (0, h / 2, 0) if prev == "Root" else (0, (prev_h + h) / 2, 0)
        P.append(part(f"Capa{i}", prev, (w, h, w - 0.75), joint, skin=skin))
        P.append(part(f"Cruz{i}", f"Capa{i}", (w - 0.75, h, w), (0, 0, 0), skin=skin))
        prev, prev_h = f"Capa{i}", h
    return {"name": "HuevoMusgo", "seed": 5, "ramps": MUSGO_RAMPS, "parts": P}


GRIETA_RAMPS = {
    "body": [(90, 30, 30), (116, 42, 40), (138, 56, 52), (158, 72, 66), (176, 90, 82)],
    "belly": [(124, 62, 58), (146, 80, 74), (166, 98, 90), (182, 116, 106), (196, 134, 122)],
    "crack": [(64, 22, 24), (78, 28, 30), (92, 34, 36), (104, 42, 42), (116, 50, 48)],
    "dark": [(70, 26, 28), (88, 34, 36), (104, 42, 44), (120, 52, 52), (136, 62, 60)],
    "moss": [(112, 40, 40), (142, 56, 54), (168, 74, 68), (190, 94, 86), (208, 116, 106)],
}


def grieta():
    """Especie 2 (referencia de Lucas, 2026-11-26): cuadrúpedo bajo de piel de roca roja agrietada,
    cabeza que es una boca en estrella de 5 pétalos (se abren para morder) con anillo de dientes,
    púas en el lomo y cola larga de 6 bloques que se curva hacia el suelo. Nada brilla.
    Rasgo de cría: la cabeza/boca grande."""
    rock = dict(belly=0.3, cracks=0.5)
    P = []
    # Cuerpo: anca atrás, pecho adelante más alto y ancho (como en el perfil de la referencia).
    P.append(part("Rear", "Root", (4, 2.6, 4), (0, 3.4, 2), skin=rock, baby=(1, 1, 0.85)))
    P.append(part("Chest", "Rear", (4.5, 3.2, 4.5), (0, 0.3, -2), pivot=(0, 0, 2.25), skin=rock, baby=(1, 1, 0.85)))
    # Cuello corto y cabeza-boca.
    P.append(part("Neck1", "Chest", (2.6, 2.4, 1.2), (0, 0.1, -2.25), pivot=(0, 0, 0.6), rot=(4, 0, 0), skin=rock, baby=0.9))
    P.append(part("Neck2", "Neck1", (2.3, 2.2, 1), (0, 0, -0.6), pivot=(0, 0, 0.5), skin=rock, baby=0.9))
    P.append(part("Head", "Neck2", (2.8, 2.8, 1), (0, 0, -0.5), pivot=(0, 0, 0.5), skin=dict(cracks=0.4), baby=1.6))
    # Fondo de la boca (oscuro, sin brillo) y anillo de dientes.
    P.append(part("Maw", "Head", (1.4, 1.4, 0.15), (0, 0, -0.55), ramp="maw", flat=True, baby=1.6))
    for i in range(8):
        a = math.radians(i * 45)
        P.append(part(f"Tooth{i + 1}", "Head", (0.22, 0.32, 0.12), (math.sin(a) * 0.82, math.cos(a) * 0.82, -0.6),
                      rot=(0, 0, -i * 45), ramp="tooth", flat=True, baby=1.6))
    # Cinco pétalos alrededor de la boca: el eje largo apunta hacia afuera; la animación los inclina
    # hacia adelante (cerrar) o los abre.
    for i in range(5):
        a = i * 72
        r = math.radians(a)
        P.append(part(f"Petal{i + 1}", "Head", (1.1, 1.8, 0.35), (math.sin(r) * 0.55, math.cos(r) * 0.55, -0.55),
                      pivot=(0, -0.9, 0), rot=(0, 0, -a), skin=dict(cracks=0.3), baby=1.8))
    # Púas en el lomo, inclinadas hacia atrás.
    spikes = (("Chest", -1.4), ("Chest", 0), ("Chest", 1.4), ("Rear", -1), ("Rear", 0.8))
    for i, (parent, z) in enumerate(spikes, 1):
        top = 1.6 if parent == "Chest" else 1.3
        P.append(part(f"Spike{i}", parent, (0.35, 1.2, 0.35), (0, top, z), pivot=(0, -0.6, 0), rot=(30, 0, 0),
                      ramp="dark", pattern="solid", baby=0.5))
    # Patas: delanteras en el pecho, traseras más gruesas en el anca.
    mirrored(part("LegFU", "Chest", (1.6, 1.4, 1.6), (1.6, -1.3, -0.6), pivot=(0, 0.55, 0), skin=rock, baby=0.8), P)
    mirrored(part("LegFL", "LegFU*", (1.5, 1.4, 1.8), (0, -0.7, 0), pivot=(0, 0.7, 0), skin=rock, baby=0.8), P)
    mirrored(part("LegBU", "Rear", (1.8, 1.5, 1.9), (1.4, -1.0, 0.5), pivot=(0, 0.55, 0), skin=rock, baby=0.8), P)
    mirrored(part("LegBL", "LegBU*", (1.6, 1.4, 2), (0, -0.75, 0), pivot=(0, 0.7, 0), skin=rock, baby=0.8), P)
    # Cola larga: seis bloques que se afinan y se curvan hacia el suelo.
    prev, plen = "Rear", 4
    sizes = ((2.4, 2.1), (2, 1.8), (1.7, 1.5), (1.4, 1.2), (1.1, 1), (0.8, 0.8))
    for i, (w, h) in enumerate(sizes, 1):
        P.append(part(f"Tail{i}", prev, (w, h, 2), (0, 0.2 if i == 1 else 0, plen / 2), pivot=(0, 0, -1),
                      rot=(0 if i == 1 else 5, 15 if i >= 4 else 0, 0), skin=dict(belly=0.25, cracks=0.4),
                      baby=0.55 if i == 1 else 0.35))
        prev, plen = f"Tail{i}", 2
    return {
        "name": "Grieta",
        "seed": 21,
        "babySize": 0.4,
        "ramps": GRIETA_RAMPS,
        "solids": {"maw": (24, 20, 30), "tooth": (232, 226, 212)},
        "parts": P,
    }


def huevo_grieta():
    """Huevo de roca roja agrietada (sin planilla de Lucas: armado a ojo con la misma forma)."""
    P = []
    prev, prev_h = "Root", 0
    layers = ((2.5, 0.75), (3.25, 1.5), (3, 1.25), (2.5, 0.75), (1.75, 0.5))
    for i, (w, h) in enumerate(layers, 1):
        skin = dict(belly=0.5 if i == 1 else 0, cracks=0.7)
        joint = (0, h / 2, 0) if prev == "Root" else (0, (prev_h + h) / 2, 0)
        P.append(part(f"Capa{i}", prev, (w, h, w - 0.75), joint, skin=skin))
        P.append(part(f"Cruz{i}", f"Capa{i}", (w - 0.75, h, w), (0, 0, 0), skin=skin))
        prev, prev_h = f"Capa{i}", h
    return {"name": "HuevoGrieta", "seed": 22, "ramps": GRIETA_RAMPS, "parts": P}


if __name__ == "__main__":
    export(cuadrupedo())
    export(musgo())
    export(huevo_musgo())
    export(grieta())
    export(huevo_grieta())
