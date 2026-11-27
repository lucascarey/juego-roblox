"""Render offline (sin Studio) de una especie exportada: cajas con su atlas, proyección ortográfica.

Sirve para comparar el modelo con la planilla de Lucas cuando Studio no puede sacar capturas.
Uso: uv run --with pillow --with numpy tools/render_species.py Hermitano salida.png
Vistas: frente, perfil (cabeza a la izquierda), arriba y 3/4. La pose es la de reposo.
"""

import json
import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
UPSCALE = 8  # el atlas se guarda agrandado 8x
PPS = 4


def rot(deg):
    x, y, z = (math.radians(v) for v in deg)
    cx, sx, cy, sy, cz, sz = math.cos(x), math.sin(x), math.cos(y), math.sin(y), math.cos(z), math.sin(z)
    rx = np.array([[1, 0, 0], [0, cx, -sx], [0, sx, cx]])
    ry = np.array([[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]])
    rz = np.array([[cz, -sz, 0], [sz, cz, 0], [0, 0, 1]])
    return rx @ ry @ rz  # CFrame.Angles


def solve(parts):
    """CFrame (R, p) de cada pieza en reposo, en el espacio de la Root."""
    world = {"Root": (np.eye(3), np.zeros(3))}
    for p in parts:
        R0, p0 = world[p["parent"]]
        R = R0 @ (rot(p["rot"]) if p["rot"] else np.eye(3)) @ (rot(p["tilt"]) if p.get("tilt") else np.eye(3))
        joint = p0 + R0 @ np.array(p["joint"])
        pivot = np.array(p["pivot"]) if p["pivot"] else np.zeros(3)
        world[p["name"]] = (R, joint - R @ pivot)
    return world


# Caras: normal local, ejes (u, v) en el espacio de la pieza (v hacia abajo en la imagen del atlas).
FACES = {
    "Front": ((0, 0, -1), (-1, 0, 0), (0, -1, 0)),
    "Back": ((0, 0, 1), (1, 0, 0), (0, -1, 0)),
    "Left": ((-1, 0, 0), (0, 0, 1), (0, -1, 0)),
    "Right": ((1, 0, 0), (0, 0, -1), (0, -1, 0)),
    "Top": ((0, 1, 0), (-1, 0, 0), (0, 0, 1)),
    "Bottom": ((0, -1, 0), (-1, 0, 0), (0, 0, -1)),
}


def render(data, atlas, view, size=520, light=np.array([0.35, 0.8, -0.45])):
    parts = data["parts"]
    world = solve(parts)
    light = light / np.linalg.norm(light)
    # Vista: cámara mirando en dirección d (ortográfica), arriba ~Y.
    yaw, pitch = view
    d = np.array([math.sin(yaw) * math.cos(pitch), -math.sin(pitch), math.cos(yaw) * math.cos(pitch)])
    right = np.cross(d, [0, 1, 0])
    if np.linalg.norm(right) < 1e-6:
        right = np.array([1.0, 0, 0])
    right /= np.linalg.norm(right)
    up = np.cross(right, d)
    quads = []
    for p in parts:
        R, pos = world[p["name"]]
        half = np.array(p["size"]) / 2
        color = data["palette"].get(p["ramp"], (255, 0, 255))
        for face, (n, u, v) in FACES.items():
            n, u, v = np.array(n, float), np.array(u, float), np.array(v, float)
            nw = R @ n
            if nw @ d >= 0:
                continue  # de espaldas
            shade = 0.55 + 0.45 * max(0.0, nw @ light)
            center = pos + R @ (n * half)
            du, dv = abs(u @ half) * 2, abs(v @ half) * 2
            o = center - R @ (u * du / 2) - R @ (v * dv / 2)
            rect = p.get("faces", {}).get(face)
            nu, nv = max(1, round(du * PPS)), max(1, round(dv * PPS))
            for iu in range(nu):
                for iv in range(nv):
                    if rect and not p["flat"]:
                        px = int((rect[0] * PPS + iu + 0.5) * UPSCALE)
                        py = int((rect[1] * PPS + iv + 0.5) * UPSCALE)
                        c = atlas.getpixel((min(px, atlas.width - 1), min(py, atlas.height - 1)))
                    else:
                        c = color
                    a = o + R @ (u * du * iu / nu) + R @ (v * dv * iv / nv)
                    b = a + R @ (u * du / nu)
                    cc = b + R @ (v * dv / nv)
                    dd = a + R @ (v * dv / nv)
                    depth = ((a + cc) / 2) @ d
                    quads.append((depth, [a, b, cc, dd], tuple(int(min(255, ch * shade * 1.5)) for ch in c[:3])))
    pts = np.array([q for _, qs, _ in quads for q in qs])
    xs, ys = pts @ right, pts @ up
    span = max(xs.max() - xs.min(), ys.max() - ys.min())
    k = (size * 0.9) / span
    cx, cy = (xs.max() + xs.min()) / 2, (ys.max() + ys.min()) / 2
    img = Image.new("RGB", (size, size), (255, 255, 255))
    dr = ImageDraw.Draw(img)
    for _, qs, c in sorted(quads, key=lambda q: -q[0]):
        poly = [(size / 2 + (q @ right - cx) * k, size / 2 - (q @ up - cy) * k) for q in qs]
        dr.polygon(poly, fill=c)
    return img


def main():
    name, out = sys.argv[1], sys.argv[2]
    data = json.loads((ROOT / "src" / "shared" / "Creatures" / "Data" / f"{name}.json").read_text(encoding="utf-8"))
    atlas = Image.open(ROOT / "assets" / "textures" / f"{name}_atlas.png").convert("RGB")
    views = [(0, math.radians(12)), (math.radians(90), math.radians(10)), (math.radians(180), math.radians(89)), (math.radians(-140), math.radians(30))]
    imgs = [render(data, atlas, v) for v in views]
    sheet = Image.new("RGB", (520 * 2, 520 * 2), (255, 255, 255))
    for i, im in enumerate(imgs):
        sheet.paste(im, ((i % 2) * 520, (i // 2) * 520))
    sheet.save(out)
    print("ok", out)


if __name__ == "__main__":
    main()
