"""Genera las texturas pixeladas (en escala de grises, se tiñen en Roblox con Texture.Color3).

Cada textura es un tile de 16x16 que se repite sin cortes y se agranda x32 sin suavizado,
así Roblox no la ve borrosa. Uso: uv run --with pillow tools/gen_textures.py
"""

import random
from pathlib import Path

from PIL import Image

OUT = Path(__file__).resolve().parent.parent / "assets" / "textures"
SIZE = 16
SCALE = 32


def blobs(rng: random.Random, grid, count: int, value: int, radius: int) -> None:
    """Manchas que se envuelven en los bordes para que el tile no tenga costuras."""
    for _ in range(count):
        cx, cy = rng.randrange(SIZE), rng.randrange(SIZE)
        for dy in range(-radius, radius + 1):
            for dx in range(-radius, radius + 1):
                if dx * dx + dy * dy <= radius * radius + rng.randint(-1, 1):
                    grid[(cy + dy) % SIZE][(cx + dx) % SIZE] = value


def mottled(seed: int):
    """Piel de criatura: base clara con manchas medias y algunos píxeles oscuros y brillos."""
    rng = random.Random(seed)
    g = [[236] * SIZE for _ in range(SIZE)]
    blobs(rng, g, 7, 212, 2)
    blobs(rng, g, 5, 198, 1)
    for _ in range(14):
        g[rng.randrange(SIZE)][rng.randrange(SIZE)] = rng.choice([182, 190])
    for _ in range(8):
        g[rng.randrange(SIZE)][rng.randrange(SIZE)] = 252
    return g


def stone(seed: int):
    """Piedra: bloques con juntas oscuras y variación suave."""
    rng = random.Random(seed)
    g = [[rng.choice([222, 228, 234, 238]) for _ in range(SIZE)] for _ in range(SIZE)]
    for y in (0, 8):
        for x in range(SIZE):
            g[y][x] = 176
    for y in range(SIZE):
        off = 0 if y < 8 else 8
        g[y][(4 + off) % SIZE] = 176
    blobs(rng, g, 4, 206, 1)
    return g


def save(name: str, grid) -> None:
    img = Image.new("RGB", (SIZE, SIZE))
    for y, row in enumerate(grid):
        for x, v in enumerate(row):
            img.putpixel((x, y), (v, v, v))
    img = img.resize((SIZE * SCALE, SIZE * SCALE), Image.NEAREST)
    OUT.mkdir(parents=True, exist_ok=True)
    img.save(OUT / f"{name}.png")
    print("ok", OUT / f"{name}.png")


if __name__ == "__main__":
    save("piel", mottled(7))
    save("piedra", stone(11))
