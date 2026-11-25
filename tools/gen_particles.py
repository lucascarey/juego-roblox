"""Texturas pixeladas para partículas (blancas: se tiñen con ParticleEmitter.Color).

Uso: uv run --with pillow tools/gen_particles.py
Genera en assets/textures/:
  - particula_bloque.png: un bloque con borde (tierra, terrones, pedacitos de pasto)
  - particula_polvo.png:  nube de polvo pixelada con bordes escalonados
"""

import random
from pathlib import Path

from PIL import Image

OUT = Path(__file__).resolve().parent.parent / "assets" / "textures"
UP = 16  # agrandado sin suavizado para que Roblox no lo desenfoque


def save(img, name):
    OUT.mkdir(parents=True, exist_ok=True)
    img.resize((img.width * UP, img.height * UP), Image.NEAREST).save(OUT / name)
    print("ok", name)


def bloque():
    # 8x8: relleno claro, borde un poco más oscuro, un brillo arriba a la izquierda.
    img = Image.new("RGBA", (8, 8), (0, 0, 0, 0))
    for y in range(8):
        for x in range(8):
            edge = x in (0, 7) or y in (0, 7)
            v = 200 if edge else 255
            if not edge and x <= 2 and y <= 2:
                v = 255
            elif not edge and (x + y) % 5 == 0:
                v = 232
            img.putpixel((x, y), (v, v, v, 255))
    return img


def polvo():
    # 16x16: círculo con alpha en escalones (pixel art), centro más denso.
    rng = random.Random(4)
    img = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
    for y in range(16):
        for x in range(16):
            d = ((x - 7.5) ** 2 + (y - 7.5) ** 2) ** 0.5 + rng.uniform(-0.6, 0.6)
            if d < 4:
                a = 230
            elif d < 6:
                a = 160
            elif d < 7.6:
                a = 80
            else:
                continue
            img.putpixel((x, y), (255, 255, 255, a))
    return img


if __name__ == "__main__":
    save(bloque(), "particula_bloque.png")
    save(polvo(), "particula_polvo.png")
