"""Kit de ambiente low-poly (estilo de la referencia) para exportar a Roblox.

Corre en Blender sin ventana:
  blender -b --factory-startup --python tools/blender_kit.py -- <salida.glb> [preview.png]

Genera piedras biseladas y despuntadas, rocas facetadas, matas de pasto, helecho,
pinos de borde dentado, hiedra colgante y arbustos. 1 metro = 1 stud (se reescala al importar).
Cada objeto tiene un solo material para que Roblox lo importe como un MeshPart con su color.
"""

import math
import random
import sys

import bmesh
import bpy
from mathutils import Vector

args = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
OUT = args[0] if args else "evo_kit.glb"
PREVIEW = args[1] if len(args) > 1 else None

rng = random.Random(7)
bpy.ops.wm.read_factory_settings(use_empty=True)
col = bpy.context.scene.collection


def mat(nm, rgb):
    m = bpy.data.materials.new(nm)
    m.use_nodes = True
    bsdf = next(n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    bsdf.inputs["Base Color"].default_value = (*rgb, 1)
    bsdf.inputs["Roughness"].default_value = 0.9
    m.diffuse_color = (*rgb, 1)
    return m


# Colores en lineal (Blender); Roblox los recibe convertidos a sRGB.
M = {
    "Stone": mat("Stone", (0.30, 0.33, 0.27)),
    "Rock": mat("Rock", (0.20, 0.21, 0.19)),
    "Grass": mat("Grass", (0.20, 0.42, 0.05)),
    "Fern": mat("Fern", (0.10, 0.30, 0.06)),
    "Pine": mat("Pine", (0.03, 0.14, 0.06)),
    "Bark": mat("Bark", (0.12, 0.07, 0.04)),
    "Ivy": mat("Ivy", (0.07, 0.24, 0.04)),
    "Bush": mat("Bush", (0.09, 0.27, 0.05)),
}


def finish(bm, nm, material, loc, parent=None):
    me = bpy.data.meshes.new(nm)
    bm.to_mesh(me)
    bm.free()
    for p in me.polygons:
        p.use_smooth = False
    me.materials.append(material)
    ob = bpy.data.objects.new(nm, me)
    col.objects.link(ob)
    ob.location = loc
    if parent:
        ob.parent = parent
    return ob


def jitter(bm, amt):
    for v in bm.verts:
        v.co += Vector((rng.uniform(-amt, amt), rng.uniform(-amt, amt), rng.uniform(-amt, amt)))


# --- Bloques de piedra biselados, irregulares y con una esquina rota (ruinas)
def stone_block(nm, size, loc):
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bmesh.ops.scale(bm, vec=Vector(size), verts=bm.verts)
    bmesh.ops.bevel(bm, geom=list(bm.edges), offset=min(size) * 0.09, segments=1, affect="EDGES")
    jitter(bm, min(size) * 0.035)
    c = Vector((rng.choice([-1, 1]) * size[0] / 2, rng.choice([-1, 1]) * size[1] / 2, size[2] / 2))
    geom = bm.verts[:] + bm.edges[:] + bm.faces[:]
    res = bmesh.ops.bisect_plane(bm, geom=geom, plane_co=c * 0.78, plane_no=c.normalized(), clear_outer=True)
    bmesh.ops.contextual_create(bm, geom=[e for e in res["geom_cut"] if isinstance(e, bmesh.types.BMEdge)])
    return finish(bm, nm, M["Stone"], loc)


# --- Rocas facetadas
def rock(nm, scale, loc, sub=1):
    bm = bmesh.new()
    bmesh.ops.create_icosphere(bm, subdivisions=sub, radius=1.0)
    for v in bm.verts:
        v.co *= rng.uniform(0.82, 1.15)
        v.co.z = max(v.co.z, -0.35)
    bmesh.ops.scale(bm, vec=Vector(scale), verts=bm.verts)
    return finish(bm, nm, M["Rock"], loc)


def blade(bm, base, h, w, yaw, lean):
    d = Vector((math.cos(yaw), math.sin(yaw), 0))
    side = Vector((-d.y, d.x, 0)) * (w / 2)
    tip = base + Vector((0, 0, h)) + d * lean
    mid = base + Vector((0, 0, h * 0.5)) + d * lean * 0.35
    vs = [bm.verts.new(p) for p in (base - side, base + side, mid + side * 0.6, mid - side * 0.6, tip)]
    bm.faces.new((vs[0], vs[1], vs[2], vs[3]))
    bm.faces.new((vs[3], vs[2], vs[4]))


# --- Matas de pasto alto
def grass(nm, n, hmin, hmax, loc, spread=0.6):
    bm = bmesh.new()
    for _ in range(n):
        base = Vector((rng.uniform(-spread, spread), rng.uniform(-spread, spread), 0))
        blade(bm, base, rng.uniform(hmin, hmax), rng.uniform(0.16, 0.26), rng.uniform(0, 6.28), rng.uniform(0.2, 0.7))
    return finish(bm, nm, M["Grass"], loc)


# --- Helecho: frondas arqueadas
def fern(nm, loc):
    bm = bmesh.new()
    for i in range(7):
        yaw = i / 7 * 6.28 + rng.uniform(-0.2, 0.2)
        d = Vector((math.cos(yaw), math.sin(yaw), 0))
        side = Vector((-d.y, d.x, 0))
        length = rng.uniform(1.4, 2.0)
        prev = None
        for s in range(5):
            t = s / 4
            p = d * length * t + Vector((0, 0, math.sin(t * 2.6) * 0.9))
            w = 0.45 * (1 - t) + 0.05
            a, b = bm.verts.new(p - side * w), bm.verts.new(p + side * w)
            if prev:
                bm.faces.new((prev[0], prev[1], b, a))
            prev = (a, b)
    return finish(bm, nm, M["Fern"], loc)


# --- Pino: tronco hexagonal + niveles en forma de estrella (borde dentado)
def pine(nm, loc, tiers=4, h=10):
    empty = bpy.data.objects.new(nm, None)
    col.objects.link(empty)
    empty.location = loc
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, segments=6, radius1=0.45, radius2=0.35, depth=h * 0.45)
    bmesh.ops.translate(bm, vec=Vector((0, 0, h * 0.225)), verts=bm.verts)
    finish(bm, nm + "_Trunk", M["Bark"], (0, 0, 0), empty)
    bm = bmesh.new()
    z = h * 0.18
    for t in range(tiers):
        r = (2.6 - t * 0.55) * (h / 10)
        th = (3.4 - t * 0.35) * (h / 10)
        n = 8
        ring = []
        for k in range(n * 2):
            a = k / (n * 2) * 6.283 + t * 0.4
            rr = r * (1.0 if k % 2 == 0 else 0.72) * rng.uniform(0.9, 1.08)
            dz = rng.uniform(-0.15, 0.1) - (0.25 if k % 2 == 0 else 0)
            ring.append(bm.verts.new((math.cos(a) * rr, math.sin(a) * rr, z + dz)))
        apex = bm.verts.new((rng.uniform(-0.1, 0.1), rng.uniform(-0.1, 0.1), z + th))
        for k in range(n * 2):
            bm.faces.new((ring[k], ring[(k + 1) % (n * 2)], apex))
        bm.faces.new(list(reversed(ring)))
        z += th * 0.52
    finish(bm, nm + "_Leaves", M["Pine"], (0, 0, 0), empty)
    return empty


# --- Tira de hiedra colgante (hojas en rombo); el origen está arriba
def ivy(nm, length, loc):
    bm = bmesh.new()
    y = 0.0
    while y < length:
        s = rng.uniform(0.35, 0.6)
        c = Vector((rng.uniform(-0.25, 0.25), rng.uniform(-0.05, 0.05), -y))
        offs = ((0, 0, s), (s * 0.8, -0.05, 0), (0, 0, -s), (-s * 0.8, -0.05, 0))
        bm.faces.new([bm.verts.new(c + Vector(o)) for o in offs])
        y += s * 0.75
    return finish(bm, nm, M["Ivy"], loc)


# --- Arbusto: icosferas aplastadas juntas
def bush(nm, loc):
    bm = bmesh.new()
    for _ in range(4):
        t = bmesh.ops.create_icosphere(bm, subdivisions=1, radius=rng.uniform(0.7, 1.1))
        off = Vector((rng.uniform(-0.8, 0.8), rng.uniform(-0.8, 0.8), rng.uniform(0.4, 0.8)))
        bmesh.ops.scale(bm, vec=Vector((1, 1, 0.8)), verts=t["verts"])
        bmesh.ops.translate(bm, vec=off, verts=t["verts"])
    return finish(bm, nm, M["Bush"], loc)


stone_block("StoneBlock_A", (3, 3, 2.6), (0, 0, 1.3))
stone_block("StoneBlock_B", (3.2, 2.4, 2.2), (5, 0, 1.1))
stone_block("StoneBlock_C", (6, 3, 1.6), (11, 0, 0.8))
stone_block("StoneSlab_A", (3, 2.8, 0.5), (17, 0, 0.25))
rock("Rock_A", (2.2, 1.8, 1.4), (24, 0, 0.6))
rock("Rock_B", (1.4, 1.2, 1.1), (29, 0, 0.4))
rock("Rock_C", (3.4, 2.6, 2.0), (35, 0, 0.8), sub=2)
grass("Grass_A", 14, 0.9, 1.8, (42, 0, 0))
grass("Grass_B", 22, 1.2, 2.4, (46, 0, 0), spread=0.9)
fern("Fern_A", (51, 0, 0))
pine("Pine_A", (58, 0, 0))
pine("Pine_B", (66, 0, 0), tiers=5, h=13)
ivy("Ivy_Short", 3, (72, 0, 3))
ivy("Ivy_Long", 8, (74, 0, 8))
bush("Bush_A", (79, 0, 0))

tris = sum(len(o.data.polygons) for o in col.objects if o.type == "MESH")
print("KIT objects", len(col.objects), "faces", tris)

bpy.ops.export_scene.gltf(filepath=OUT, export_format="GLB", use_selection=False, export_apply=True)
print("KIT exported", OUT)

if PREVIEW:
    scene = bpy.context.scene
    cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam"))
    col.objects.link(cam)
    cam.location = (40, -45, 18)
    cam.rotation_euler = (math.radians(72), 0, 0)
    cam.data.lens = 28
    scene.camera = cam
    sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
    col.objects.link(sun)
    sun.rotation_euler = (math.radians(50), math.radians(20), math.radians(30))
    try:
        scene.render.engine = "BLENDER_WORKBENCH"
    except TypeError as e:
        print("engine", e)
    scene.display.shading.color_type = "MATERIAL"
    scene.display.shading.light = "STUDIO"
    scene.render.resolution_x, scene.render.resolution_y = 1280, 640
    scene.render.filepath = PREVIEW
    bpy.ops.render.render(write_still=True)
    print("KIT preview", PREVIEW)
