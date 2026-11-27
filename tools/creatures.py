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


def part(name, parent, size, joint, pivot=None, rot=None, ramp="body", neon=False, flat=False, pattern="mottled", baby=1.0, skin=None, tilt=None):
    return {
        "name": name,
        "parent": parent,
        "size": list(size),
        "joint": list(joint),
        "pivot": list(pivot) if pivot else None,
        "rot": list(rot) if rot else None,
        "tilt": list(tilt) if tilt else None,  # segunda rotación, sobre los ejes ya girados por rot
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


def apply_scale(species):
    """Escala toda la especie (medidas, articulaciones, pivotes). Va antes de pintar el atlas, así la
    densidad de píxeles sigue siendo la misma que en las demás especies."""
    s = species.get("scale", 1)
    if s == 1:
        return
    for p in species["parts"]:
        p["size"] = [v * s for v in p["size"]]
        p["joint"] = [v * s for v in p["joint"]]
        if p["pivot"]:
            p["pivot"] = [v * s for v in p["pivot"]]


def export(species):
    apply_scale(species)
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
    """Especie 2 (referencia de Lucas, 2026-11-26): carnívora BÍPEDA de piel de roca roja agrietada.
    Según la planilla (frente y atrás muestran solo dos patas): cuerpo horizontal sobre dos patas en
    las caderas (muslo grueso, caña y pie con dedos hacia adelante), pecho grande adelante con hombros
    marcados, cuello corto, cabeza formada por los pétalos de la estrella, púas en el lomo y cola larga
    de contrapeso que baja hacia el suelo y se enrosca al final. Nada brilla.
    Rasgo de cría: la cabeza/boca grande."""
    rock = dict(belly=0.3, cracks=0.5)
    P = []
    # Cuerpo: caderas (raíz, sobre las patas) y pecho grande adelante, un poco más alto.
    P.append(part("Rear", "Root", (3, 3.4, 3), (0, 5.3, 0), skin=rock, baby=(1, 1, 0.85)))
    # Columna arqueada hacia abajo: el lomo más alto está en las caderas y el pecho baja hacia adelante.
    # Arco en bloques escalonados: caderas (lo más alto) -> lomo -10° -> pecho otros -10°, y la cola
    # baja del otro lado. Cada bloque gira respecto del anterior, así el arco se lee de perfil.
    P.append(part("Spine", "Rear", (3.3, 3.8, 2.2), (0, 0.1, -1.5), pivot=(0, 0, 1.1), rot=(-10, 0, 0), skin=rock, baby=(1, 1, 0.85)))
    P.append(part("Chest", "Spine", (3.6, 4, 2.8), (0, 0, -1.1), pivot=(0, 0, 1.4), rot=(-10, 0, 0), skin=rock, baby=(1, 1, 0.85)))
    # Cuello y cabeza: la cabeza ES la estrella. Un núcleo chico (oculto entre los pétalos) y cinco
    # pétalos grandes de dos segmentos que, cerrados, forman el capullo en gota; al abrir muestran la
    # boca. Sin bloque cuadrado a la vista.
    P.append(part("Neck1", "Chest", (1.8, 1.8, 1.2), (0, 0.3, -1.4), pivot=(0, 0, 0.6), rot=(6, 0, 0), skin=rock, baby=0.9))
    P.append(part("Neck2", "Neck1", (1.5, 1.5, 1), (0, 0, -0.6), pivot=(0, 0, 0.5), rot=(6, 0, 0), skin=rock, baby=0.9))
    P.append(part("HeadBack", "Neck2", (1.6, 1.6, 0.8), (0, 0, -0.5), pivot=(0, 0, 0.4), rot=(6, 0, 0), skin=dict(cracks=0.4), baby=1.2))
    P.append(part("Head", "HeadBack", (1.5, 1.5, 0.6), (0, 0, -0.4), pivot=(0, 0, 0.3), skin=dict(cracks=0.3), baby=1.25))
    # Fondo de la boca (oscuro, sin brillo) y anillo de dientes, en el frente del núcleo.
    P.append(part("Maw", "Head", (1.1, 1.1, 0.15), (0, 0, -0.33), ramp="maw", flat=True, baby=1.25))
    for i in range(12):
        a = math.radians(i * 30)
        P.append(part(f"Tooth{i + 1}", "Head", (0.15, 0.22, 0.1), (math.sin(a) * 0.55, math.cos(a) * 0.55, -0.38),
                      rot=(0, 0, -i * 30), ramp="tooth", flat=True, baby=1.25))
    # Cinco pétalos de dos segmentos que forman la cabeza, con dientes chicos en la cara de adentro.
    for i in range(5):
        a = i * 72
        r = math.radians(a)
        base, tip = f"Petal{i + 1}", f"PetalTip{i + 1}"
        P.append(part(base, "Head", (1.45, 1.7, 0.35), (math.sin(r) * 0.4, math.cos(r) * 0.4, -0.3),
                      pivot=(0, -0.85, 0), rot=(0, 0, -a), tilt=(-43, 0, 0), skin=dict(cracks=0.3), baby=1.25))
        P.append(part(tip, base, (1.15, 1.4, 0.3), (0, 0.85, 0), pivot=(0, -0.7, 0), tilt=(-30, 0, 0),
                      skin=dict(cracks=0.3), baby=1.25))
        # Remate en semipunta: dos escalones que se afinan al final del flagelo.
        P.append(part(f"PetalPoint{i + 1}", tip, (0.75, 0.5, 0.26), (0, 0.7, 0), pivot=(0, -0.25, 0), skin=dict(cracks=0.2), baby=1.25))
        P.append(part(f"PetalPointTip{i + 1}", f"PetalPoint{i + 1}", (0.38, 0.35, 0.22), (0, 0.25, 0), pivot=(0, -0.17, 0),
                      skin=dict(cracks=0.1), baby=1.25))
        # Tres filas de dientes por segmento (centro y dos a los costados, pedido de Lucas).
        k = 0
        for x in (-0.45, 0, 0.45):
            for y in (-0.45, 0, 0.45):
                k += 1
                P.append(part(f"PetalTooth{i + 1}{k}", base, (0.16, 0.18, 0.12), (x, y, -0.22),
                              ramp="tooth", flat=True, baby=1.25))
        k = 0
        for x in (-0.35, 0, 0.35):
            for y in (-0.35, 0, 0.35):
                k += 1
                P.append(part(f"PetalTipTooth{i + 1}{k}", tip, (0.14, 0.16, 0.1), (x, y, -0.19),
                              ramp="tooth", flat=True, baby=1.25))
    # Dos patas de raptor (pedido de Lucas, 2026-11-26: "como las de un velociraptor"), digitígradas:
    # muslo grande y ancho hacia adelante (rodilla adelante), caña larga hacia atrás, metatarso hacia
    # adelante (el talón levantado es la articulación que se ve "al revés") y solo los dedos en el piso.
    # El metatarso va paralelo al muslo (el animador lo mantiene así: pantógrafo) y la base del
    # metatarso queda justo debajo de la cadera:
    #   muslo 3.0 a 35° adelante (1.72) + metatarso 1.8 a 35° (1.03) = caña 3.6 a 49.8° atrás (2.75)
    # La cría ya tiene patas largas (babyScale > 1).
    mirrored(part("LegBU", "Rear", (1.7, 3.8, 2.6), (1.85, -0.6, -1.5), pivot=(0, 1.3, 0), rot=(35, 0, 0),
                  skin=rock, baby=1.1), P)
    mirrored(part("LegBL", "LegBU*", (1.25, 3.9, 1.35), (0, -1.7, 0), pivot=(0, 1.75, 0), rot=(-84.8, 0, 0),
                  skin=rock, baby=1.15), P)
    mirrored(part("LegBM", "LegBL*", (0.95, 1.95, 1.0), (0, -1.85, 0), pivot=(0, 0.825, 0), rot=(84.8, 0, 0),
                  skin=rock, baby=1.15), P)
    # Pie: base chica de los dedos (lo único que apoya) y tres dedos que se abren poco, como un raptor.
    mirrored(part("Foot", "LegBM*", (1.4, 0.55, 1.3), (0, -0.975, 0), pivot=(0, 0.275, 0.2), rot=(-35, 0, 0),
                  skin=dict(cracks=0.3), baby=1.0), P)
    # Pies grandes respecto de la pata (pedido de Lucas): dedos y garras 1.5 veces más grandes.
    for j, (yaw, ln) in enumerate(((18, 1.5), (0, 1.95), (-18, 1.5)), 1):
        mirrored(part(f"Toe{j}", "Foot*", (0.45, 0.5, ln), (0, -0.04, -0.4), pivot=(0, 0, ln / 2), rot=(0, yaw, 0),
                      skin=dict(cracks=0.2), baby=1.0), P)
        # Punta de cada dedo: una garra que se afina en dos bloques y apunta hacia abajo y adelante.
        mirrored(part(f"Claw{j}", f"Toe{j}*", (0.36, 0.36, 0.65), (0, 0, -ln / 2), pivot=(0, 0, 0.3), rot=(-8, 0, 0),
                      ramp="dark", pattern="solid", baby=1.0), P)
        mirrored(part(f"ClawTip{j}", f"Claw{j}*", (0.2, 0.2, 0.5), (0, -0.03, -0.32), pivot=(0, 0, 0.22), rot=(-8, 0, 0),
                      ramp="dark", pattern="solid", baby=1.0), P)
    # Cola de contrapeso (~1.4 veces el cuerpo, como en la planilla): seis bloques que se afinan, bajan
    # hacia el suelo y se enroscan al final, sin quedar más abajo que los pies.
    prev, plen = "Rear", 3
    # La cola es la continuación del cuerpo: el primer bloque casi del grosor de la cadera y centrado con
    # ella, y se afina hacia la punta. Todas crecen igual que el cuerpo (en las crías solo es más corta),
    # así el paso de torso a cola es el mismo en todas las edades (pedido de Lucas).
    sizes = ((2.7, 3.0), (2.15, 2.25), (1.65, 1.65), (1.25, 1.2), (0.95, 0.85), (0.7, 0.65))
    for i, (w, h) in enumerate(sizes, 1):
        P.append(part(f"Tail{i}", prev, (w, h, 1.9), (0, 0, plen / 2), pivot=(0, 0, -0.95),
                      rot=(18 if i == 1 else 6.5, 16 if i >= 5 else 0, 0), skin=dict(belly=0.25, cracks=0.4),
                      baby=(1, 1, 0.7)))
        prev, plen = f"Tail{i}", 1.9
    # Púas en el lomo, del pecho a la cola, inclinadas hacia atrás.
    spikes = (("Chest", -0.8, 2), ("Chest", 0.6, 2), ("Spine", 0, 1.9), ("Rear", -0.6, 1.7), ("Rear", 0.7, 1.7),
              ("Tail1", 0, 1.5), ("Tail2", 0, 1.1), ("Tail3", 0, 0.8))
    # Articuladas en dos tramos (el animador las hace tambalear) y apenas más largas: 0.7 + 0.55.
    for i, (parent, z, top) in enumerate(spikes, 1):
        P.append(part(f"Spike{i}", parent, (0.3, 0.7, 0.3), (0, top, z), pivot=(0, -0.35, 0), rot=(30, 0, 0),
                      ramp="dark", pattern="solid", baby=0.5))
        P.append(part(f"SpikeTip{i}", f"Spike{i}", (0.2, 0.55, 0.2), (0, 0.35, 0), pivot=(0, -0.275, 0),
                      rot=(8, 0, 0), ramp="dark", pattern="solid", baby=0.5))
    return {
        "name": "Grieta",
        "seed": 21,
        "scale": 0.6,  # adulta a la mitad del tamaño de Musgo (pedido de Lucas)
        "babySize": 0.65,  # cría al 65% de la adulta: menos diferencia entre etapas
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
    return {"name": "HuevoGrieta", "seed": 22, "scale": 0.7, "ramps": GRIETA_RAMPS, "parts": P}


HERMITANO_RAMPS = {
    # Con la luz de Roblox el verde sube ~1.65x y el azul ~2x (medido contra la planilla): rampas
    # oscuras y tirando a oliva para que se vean como el musgo de la referencia.
    "body": [(28, 36, 14), (36, 46, 18), (46, 56, 24), (56, 68, 30), (68, 80, 36)],
    "moss": [(40, 48, 20), (50, 58, 24), (60, 68, 30), (72, 82, 36), (86, 96, 44)],
    "belly": [(18, 24, 10), (24, 30, 12), (30, 38, 16), (38, 46, 20), (46, 56, 24)],
    "dark": [(10, 14, 6), (14, 20, 8), (20, 26, 12), (26, 34, 16), (34, 42, 20)],
    "stone": [(36, 35, 28), (44, 43, 34), (54, 52, 42), (64, 62, 50), (76, 74, 60)],
}


def _mat_y(a):
    c, s = math.cos(a), math.sin(a)
    return [[c, 0, s], [0, 1, 0], [-s, 0, c]]


def _mat_z(a):
    c, s = math.cos(a), math.sin(a)
    return [[c, -s, 0], [s, c, 0], [0, 0, 1]]


def _mul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)] for i in range(3)]


def _T(a):
    return [[a[j][i] for j in range(3)] for i in range(3)]


def _rot_to(d):
    """Giro que lleva el eje -Y de una pieza a la dirección d (primero abre en Z, después gira en Y)."""
    x, y, z = d
    n = math.sqrt(x * x + y * y + z * z)
    x, y, z = x / n, y / n, z / n
    th = math.acos(max(-1, min(1, -y)))
    ph = math.atan2(-z, x) if abs(x) + abs(z) > 1e-6 else 0
    return _mul(_mat_y(ph), _mat_z(th))


def _euler(m):
    """Ángulos (grados) tales que CFrame.Angles(x, y, z) = Rx*Ry*Rz = m."""
    ry = math.asin(max(-1, min(1, m[0][2])))
    rx = math.atan2(-m[1][2], m[2][2])
    rz = math.atan2(-m[0][1], m[0][0])
    return (round(math.degrees(rx), 2), round(math.degrees(ry), 2), round(math.degrees(rz), 2))


def limb(P, parent, joint, segs, **kw):
    """Cadena de piezas del lado derecho (+X) que cuelgan de su articulación (pivote arriba, eje -Y);
    mirrored() arma el lado izquierdo. segs: (nombre, (ancho, largo, prof), dirección, extra).
    La dirección es en el espacio del cuerpo; cada pieza gira respecto de la anterior."""
    R = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
    par, j = parent, joint
    for name, (w, ln, dp), d, extra in segs:
        Rw = _rot_to(d)
        opts = dict(kw)
        opts.update(extra or {})
        mirrored(part(name, par, (w, ln, dp), j, pivot=(0, ln / 2, 0), rot=_euler(_mul(_T(R), Rw)), **opts), P)
        R, par, j = Rw, name + "*", (0, -ln / 2, 0)
    return R


def hermitano():
    """Especie 3 (planilla de Lucas, 2026-11-27): omnívoro acorazado, cruza de cangrejo ermitaño y mulita.
    Lectura de la planilla (frente, perfil, arriba y 3/4): caparazón grande como una losa redonda de
    musgo, con laterales verticales hondos que chorrean y el techo en domo bajo; piedras grises,
    florcitas blancas y mechones de pasto arriba. Debajo, un cuerpo oscuro con 2 barras de la boca y
    2 flagelos. 6 patas cortas y gruesas de cangrejo (3 por lado, en abanico: adelante, al costado y
    atrás), cada una con 3 falanges: la primera sale de abajo del caparazón hacia afuera hasta la
    rodilla, la segunda baja casi vertical y la tercera termina en punta. 2 pinzas adelante con 3
    falanges (brazo con piedras, muñeca y mano grande) más el dedo móvil. Sin cola ni ojos. Nada brilla.
    Entre cría y adulto solo cambia el tamaño (babyScale 1 en todo)."""
    P = []
    # Cuerpo bajo el caparazón (Rear, de 1.6 a 3.6 del piso) y frente con la boca (Chest).
    BODY_Y, BODY_H = 2.6, 2.0
    P.append(part("Rear", "Root", (5.0, BODY_H, 5.25), (0, BODY_Y, 0.35), ramp="belly", skin=dict(moss=0.15)))
    P.append(part("Chest", "Rear", (3.75, 1.75, 1.25), (0, -0.1, -2.6), pivot=(0, 0, 0.625), ramp="belly", skin=dict(moss=0.1)))
    # Boca (frente de la planilla: cuatro barras): las dos del centro fijas y las dos de afuera son los
    # flagelos, de tres tramos, que se mueven siempre.
    mirrored(part("Mouth", "Chest", (0.5, 1.0, 0.35), (0.35, -0.6, -0.55), pivot=(0, 0.5, 0), rot=(8, 0, 0), ramp="dark", pattern="solid"), P)
    mirrored(part("Flag1", "Chest", (0.45, 0.6, 0.4), (1.0, -0.6, -0.55), pivot=(0, 0.3, 0), rot=(10, 0, 4), ramp="body", pattern="solid"), P)
    mirrored(part("Flag2", "Flag1*", (0.4, 0.5, 0.35), (0, -0.3, 0), pivot=(0, 0.25, 0), rot=(6, 0, 0), ramp="body", pattern="solid"), P)
    mirrored(part("Flag3", "Flag2*", (0.3, 0.45, 0.3), (0, -0.25, 0), pivot=(0, 0.225, 0), rot=(6, 0, 0), ramp="dark", pattern="solid"), P)

    # Caparazón: falda de laterales verticales (de 3.0 a 5.6 del piso) y domo bajo de techo ancho
    # (hasta ~7.6), en capas en cruz para que de arriba se vea redondo.
    W, SKIRT_BOT, SKIRT_TOP, DOME = 9.5, 3.1, 4.5, 2.9
    side = dict(belly=0.4, moss=0.6, mossTop=True)
    cap = dict(moss=0.85, mossTop=True)
    sk_h = SKIRT_TOP - SKIRT_BOT
    layers = [(W, sk_h, (SKIRT_BOT + sk_h / 2) - BODY_Y - (BODY_H / 2 + sk_h / 2), side)]
    for t in (0.25, 0.75, 1.25, 1.75, 2.25, 2.65):
        w = round(W * max(0.0, 1 - (t / DOME) ** 2) ** 0.5 * 4) / 4
        layers.append((w, 0.5, 0, cap))
    prev, prev_top = "Rear", BODY_H / 2
    for i, (w, h, dy, skin) in enumerate(layers, 1):
        name = f"Shell{i}"
        ramp = "body" if i == 1 else "moss"
        # Cuatro cajas en cruz por capa: de arriba se ve redondo (con dos se veía cuadrado).
        # La falda va inclinada 6°: adelante más alto y atrás más bajo, como el perfil de la planilla.
        P.append(part(name, prev, (round(w * 0.9 * 4) / 4, h, round(w * 0.72 * 4) / 4), (0, prev_top + h / 2 + dy, 0),
                      rot=(6, 0, 0) if i == 1 else None, ramp=ramp, skin=skin))
        P.append(part(f"ShellX{i}", name, (round(w * 0.72 * 4) / 4, h, round(w * 0.9 * 4) / 4), (0, 0, 0), ramp=ramp, skin=skin))
        P.append(part(f"ShellY{i}", name, (w, h, round(w * 0.42 * 4) / 4), (0, 0, 0), ramp=ramp, skin=skin))
        P.append(part(f"ShellZ{i}", name, (round(w * 0.42 * 4) / 4, h, w), (0, 0, 0), ramp=ramp, skin=skin))
        prev, prev_top = name, h / 2
    # Lóbulo de atrás que baja (el abdomen del ermitaño, como en el perfil).
    P.append(part("ShellBack", "Shell1", (6.5, 1.75, 2.75), (0, -sk_h / 2 - 0.4, 2.6), ramp="body", skin=dict(belly=0.5, moss=0.45, mossTop=True)))

    # Lo que va arriba del domo se ubica por (x, z) sobre la capa más alta que lo cubre.
    def on_dome(x, z, lift):
        z -= 0.35  # el caparazón está centrado en el cuerpo, que está corrido 0.35 atrás
        for i in range(len(layers), 0, -1):
            w, h = layers[i - 1][0], layers[i - 1][1]
            if math.hypot(x, z) <= w * 0.46:
                return f"Shell{i}", (x, h / 2 + lift, z)
        return "Shell1", (x, layers[0][1] / 2 + lift, z)

    # Piedras (gris oscuro) encastradas en el domo, giradas a mano para que no queden alineadas.
    stones = ((-1.6, -1.2, 1.0, 25), (1.3, -1.0, 1.3, -15), (2.6, 0.9, 0.9, 40), (-0.6, 1.5, 1.1, 10), (-3.2, 1.4, 1.0, -30),
              (0.5, 0.2, 0.8, 50), (3.2, -1.8, 0.85, 20), (-2.3, 2.6, 0.75, -40), (-3.4, -1.4, 0.7, 15), (1.8, 2.9, 0.8, 5),
              (-1.0, -3.2, 0.7, 30))
    for i, (x, z, s, yaw) in enumerate(stones, 1):
        par, pos = on_dome(x, z, s * 0.15)
        P.append(part(f"Stone{i}", par, (s, s * 0.7, s), pos, rot=(8, yaw, -6), ramp="stone"))
    # Florcitas blancas con centro amarillo, apoyadas sobre el musgo.
    flowers = ((-1.8, 0.2), (2.0, -0.6), (-0.6, -0.5), (3.1, 2.2), (0.4, 2.6), (0.6, -1.8), (-3.0, 0.9))
    for i, (x, z) in enumerate(flowers, 1):
        par, pos = on_dome(x, z, 0.03)
        # Cruz de pétalos blancos (como en la planilla) con el centro amarillo.
        P.append(part(f"Flower{i}", par, (0.6, 0.06, 0.2), pos, rot=(0, 45 * (i % 2), 0), ramp="flower", flat=True))
        P.append(part(f"FlowerX{i}", f"Flower{i}", (0.2, 0.06, 0.6), (0, 0, 0), ramp="flower", flat=True))
        P.append(part(f"FlowerC{i}", f"Flower{i}", (0.2, 0.08, 0.2), (0, 0.01, 0), ramp="pollen", flat=True))
    # Mechones de pasto: dos o tres tramos finos que se mecen (el animador los mueve como antenas).
    tufts = ((-0.9, -0.6, 3), (-0.3, -0.9, 3), (-2.2, -0.9, 2), (1.9, -1.2, 2), (-2.9, -1.6, 2), (0.9, 0.5, 2), (-1.4, -2.4, 2))
    for i, (x, z, n) in enumerate(tufts, 1):
        prev, plen = None, None
        for k in range(1, n + 1):
            ln = 0.6 if k == 1 else 0.5
            if k == 1:
                prev, j = on_dome(x, z, -0.1)
            else:
                j = (0, plen / 2, 0)
            lean = (i * 37 % 30) - 15
            P.append(part(f"Grass{i}_{k}", prev, (0.25, ln, 0.25), j, pivot=(0, -ln / 2, 0),
                          rot=(lean if k == 1 else 12, 0, (i * 23 % 24) - 12), ramp="moss", pattern="solid"))
            prev, plen = f"Grass{i}_{k}", ln

    # Patas: 3 por lado, en abanico (adelante 28°, costado, atrás 28°). Salen de abajo de la falda:
    # falange 1 hacia afuera y un poco arriba hasta la rodilla (justo afuera del caparazón), falange 2
    # baja casi vertical, falange 3 en punta.
    hip_y = -0.2  # en el espacio del cuerpo (2.4 del piso)
    knee = (5.6, 3.2)  # (distancia al centro, alto): justo debajo del borde de la falda
    ankle = (6.6, 1.1)
    hip_r = 2.3
    for n, (z, yaw) in enumerate(((-1.6, 28), (0.1, 0), (1.7, -28)), 1):
        a = math.radians(yaw)

        def out(h, v, a=a):
            return (h * math.cos(a), v, -h * math.sin(a))

        hy = BODY_Y + hip_y
        f_len = math.hypot(knee[0] - hip_r, knee[1] - hy)
        t_len = math.hypot(ankle[0] - knee[0], ankle[1] - knee[1])
        limb(P, "Rear", (hip_r, hip_y, z), (
            (f"Leg{n}A", (1.6, round(f_len * 4) / 4, 1.6), out(knee[0] - hip_r, knee[1] - hy), dict(skin=dict(moss=0.6, mossTop=True))),
            (f"Leg{n}B", (1.5, round(t_len * 4) / 4, 1.5), out(ankle[0] - knee[0], ankle[1] - knee[1]), dict(skin=dict(moss=0.35, belly=0.35))),
            (f"Leg{n}C", (1.0, 1.25, 1.0), out(0.1, -1.1), dict(ramp="dark", skin=dict(belly=0.4))),
        ))
    # Pinzas: brazo (con piedras arriba) hacia adelante, afuera y arriba, muñeca que baja y mano grande
    # inclinada hacia adentro que llega al piso; el dedo móvil va del lado de adentro de la mano.
    limb(P, "Chest", (1.6, 0.1, -0.2), (
        ("ClawA", (1.6, 2.5, 1.6), (0.8, 0.9, -2.0), dict(skin=dict(moss=0.6, mossTop=True))),
        ("ClawB", (1.5, 1.5, 1.5), (0.4, -0.8, -0.9), dict(skin=dict(moss=0.45))),
        ("ClawHand", (2.0, 3.0, 1.6), (-0.7, -2.6, 0.2), dict(skin=dict(moss=0.35, belly=0.3))),
    ))
    mirrored(part("ClawFinger", "ClawHand*", (0.7, 1.6, 1.0), (-1.0, -0.6, -0.1), pivot=(0, 0.8, 0), rot=(0, 0, -10),
                  ramp="dark", skin=dict(belly=0.3)), P)
    for k, (pos, s) in enumerate((((0.15, 0.4, 0.85), 0.9), ((0.25, 0.8, -0.35), 0.75), ((0.0, 0.0, -1.05), 0.65)), 1):
        mirrored(part(f"ClawStone{k}", "ClawA*", (s, s * 0.7, s), pos, rot=(10, 20 * k, 0), ramp="stone"), P)
    # Piedras sobre el nacimiento de las patas delanteras (frente de la planilla).
    mirrored(part("LegStone1", "Leg1A*", (0.85, 0.6, 0.85), (0.85, 0.4, 0), rot=(0, 15, 0), ramp="stone"), P)
    return {
        "name": "Hermitano",
        "seed": 31,
        "babySize": 0.3,  # solo cambia el tamaño: la cría es un adulto chico
        "ramps": HERMITANO_RAMPS,
        "solids": {"flower": (238, 236, 222), "pollen": (230, 178, 64)},
        "parts": P,
    }


def huevo_hermitano():
    """Huevo de piedra con musgo arriba y alguna piedrita (sin planilla de Lucas: armado a ojo)."""
    P = []
    prev, prev_h = "Root", 0
    layers = ((2.5, 0.75, 0, 0.6), (3.25, 1.5, 0.2, 0.3), (3, 1.25, 0.5, 0), (2.5, 0.75, 0.7, 0), (1.75, 0.5, 1, 0))
    for i, (w, h, moss, belly) in enumerate(layers, 1):
        skin = dict(belly=belly, moss=moss, mossTop=i >= 3)
        joint = (0, h / 2, 0) if prev == "Root" else (0, (prev_h + h) / 2, 0)
        P.append(part(f"Capa{i}", prev, (w, h, w - 0.75), joint, ramp="stone", skin=skin))
        P.append(part(f"Cruz{i}", f"Capa{i}", (w - 0.75, h, w), (0, 0, 0), ramp="stone", skin=skin))
        prev, prev_h = f"Capa{i}", h
    P.append(part("Piedra1", "Capa3", (0.6, 0.45, 0.6), (0.9, 0.6, 0.3), rot=(0, 30, 0), ramp="dark"))
    P.append(part("Piedra2", "Capa4", (0.45, 0.35, 0.45), (-0.6, 0.35, -0.5), rot=(0, -20, 0), ramp="dark"))
    ramps = dict(HERMITANO_RAMPS, belly=HERMITANO_RAMPS["dark"])
    return {"name": "HuevoHermitano", "seed": 32, "scale": 0.8, "ramps": ramps, "parts": P}


if __name__ == "__main__":
    export(cuadrupedo())
    export(musgo())
    export(huevo_musgo())
    export(grieta())
    export(huevo_grieta())
    export(hermitano())
    export(huevo_hermitano())
