--!strict
-- Especies base "default": cajas simples y proporciones normales. Los traits las exageran después.
-- Convención: la criatura mira hacia -Z; la Root está a nivel del suelo.

local CreatureBuilder = require(script.Parent.CreatureBuilder)
local Textures = require(script.Parent.Parent.Textures)

type PartDef = CreatureBuilder.PartDef
type SpeciesDef = CreatureBuilder.SpeciesDef

local V = Vector3.new

-- Duplica una pieza en espejo (izquierda/derecha) sobre el eje X.
local function mirrored(base: PartDef, out: { PartDef })
	for _, side in { { "L", -1 }, { "R", 1 } } do
		local s = side[2] :: number
		local p = table.clone(base)
		p.name = base.name .. side[1]
		p.joint = V(base.joint.X * s, base.joint.Y, base.joint.Z)
		if base.parent ~= "Root" and base.parent:sub(-1) == "*" then
			p.parent = base.parent:sub(1, -2) .. side[1]
		end
		table.insert(out, p)
	end
end

-- Convierte una especie exportada por tools/creatures.py (JSON) al formato del builder.
local function fromData(data: any, atlas: string): SpeciesDef
	local function v3(t: { number }?): Vector3?
		return if t then Vector3.new(t[1], t[2], t[3]) else nil
	end
	local palette = {}
	for k, c in data.palette do
		palette[k] = Color3.fromRGB(c[1], c[2], c[3])
	end
	local parts: { PartDef } = {}
	for _, p in data.parts do
		table.insert(parts, {
			name = p.name,
			parent = p.parent,
			size = v3(p.size) :: Vector3,
			joint = v3(p.joint) :: Vector3,
			pivot = v3(p.pivot),
			rot = v3(p.rot),
			color = p.ramp,
			neon = p.neon,
			flat = p.flat,
			faces = p.faces,
			babyScale = if type(p.babyScale) == "table" then v3(p.babyScale) else p.babyScale,
		})
	end
	return {
		name = data.name,
		palette = palette,
		parts = parts,
		atlas = atlas,
		babySize = data.babySize,
		atlasStuds = Vector2.new(data.atlasStuds[1], data.atlasStuds[2]),
	}
end

local function bipedo(): SpeciesDef
	local parts: { PartDef } = {
		{
			name = "Torso",
			parent = "Root",
			size = V(2, 2.2, 3),
			joint = V(0, 4.6, 0),
			rot = V(8, 0, 0),
			color = "body",
		},
		{ name = "Chest", parent = "Torso", size = V(1.6, 1.2, 1.4), joint = V(0, -0.8, -0.9), color = "light" },
		{
			name = "Neck",
			parent = "Torso",
			size = V(1, 1.8, 1),
			joint = V(0, 0.7, -1.3),
			pivot = V(0, -0.8, 0),
			rot = V(-30, 0, 0),
			color = "body",
		},
		{
			name = "Head",
			parent = "Neck",
			size = V(1.6, 1.3, 2.4),
			joint = V(0, 0.9, 0),
			pivot = V(0, -0.3, 0.4),
			rot = V(22, 0, 0),
			color = "body",
		},
		{ name = "Jaw", parent = "Head", size = V(1.3, 0.4, 1.6), joint = V(0, -0.75, -0.3), color = "light" },
		{
			name = "Tail1",
			parent = "Torso",
			size = V(1.1, 1.1, 2),
			joint = V(0, 0.3, 1.5),
			pivot = V(0, 0, -1),
			rot = V(-10, 0, 0),
			color = "body",
		},
		{
			name = "Tail2",
			parent = "Tail1",
			size = V(0.75, 0.75, 2.2),
			joint = V(0, 0, 1),
			pivot = V(0, 0, -1.1),
			rot = V(-8, 0, 0),
			color = "body",
		},
		{
			name = "Tail3",
			parent = "Tail2",
			size = V(0.45, 0.45, 1.8),
			joint = V(0, 0, 1.1),
			pivot = V(0, 0, -0.9),
			rot = V(-6, 0, 0),
			color = "dark",
		},
	}
	mirrored({
		name = "Socket",
		parent = "Head",
		size = V(0.1, 0.5, 0.55),
		joint = V(0.8, 0.25, -0.4),
		color = "socket",
		flat = true,
	}, parts)
	mirrored({
		name = "ToothA",
		parent = "Head",
		size = V(0.12, 0.25, 0.15),
		joint = V(0.66, -0.72, -1),
		color = "tooth",
		flat = true,
	}, parts)
	mirrored({
		name = "ToothB",
		parent = "Head",
		size = V(0.12, 0.25, 0.15),
		joint = V(0.66, -0.72, -0.5),
		color = "tooth",
		flat = true,
	}, parts)
	mirrored({
		name = "Eye",
		parent = "Head",
		size = V(0.1, 0.32, 0.32),
		joint = V(0.86, 0.25, -0.4),
		color = "eye",
		neon = true,
	}, parts)
	mirrored({
		name = "Arm",
		parent = "Torso",
		size = V(0.4, 1, 0.4),
		joint = V(0.75, -0.2, -1.2),
		pivot = V(0, 0.45, 0),
		rot = V(-35, 0, 0),
		color = "dark",
	}, parts)
	mirrored({
		name = "Thigh",
		parent = "Torso",
		size = V(0.9, 1.9, 1.3),
		joint = V(0.8, -0.6, 0.4),
		pivot = V(0, 0.8, 0),
		rot = V(-8, 0, 0),
		color = "body",
	}, parts)
	mirrored({
		name = "Shin",
		parent = "Thigh*",
		size = V(0.55, 1.9, 0.6),
		joint = V(0, -0.9, 0.1),
		pivot = V(0, 0.9, 0),
		color = "dark",
	}, parts)
	mirrored({
		name = "Foot",
		parent = "Shin*",
		size = V(0.8, 0.3, 1.3),
		joint = V(0, -0.95, -0.25),
		pivot = V(0, 0.15, 0),
		color = "dark",
	}, parts)
	return {
		name = "Bipedo",
		palette = {
			body = Color3.fromRGB(222, 186, 98),
			light = Color3.fromRGB(240, 222, 168),
			dark = Color3.fromRGB(150, 110, 58),
			eye = Color3.fromRGB(80, 220, 255),
			socket = Color3.fromRGB(70, 48, 26),
			tooth = Color3.fromRGB(244, 238, 220),
		},
		parts = parts,
	}
end

local function serpentino(): SpeciesDef
	local parts: { PartDef } = {
		{ name = "Head", parent = "Root", size = V(1.8, 1.1, 2.1), joint = V(0, 0.6, -5), color = "body" },
		{ name = "Jaw", parent = "Head", size = V(1.5, 0.35, 1.7), joint = V(0, -0.7, -0.1), color = "light" },
	}
	mirrored({
		name = "Socket",
		parent = "Head",
		size = V(0.5, 0.12, 0.5),
		joint = V(0.6, 0.56, -0.55),
		color = "socket",
		flat = true,
	}, parts)
	mirrored({
		name = "Fang",
		parent = "Head",
		size = V(0.15, 0.4, 0.15),
		joint = V(0.45, -0.62, -0.9),
		color = "tooth",
		flat = true,
	}, parts)
	mirrored({
		name = "Eye",
		parent = "Head",
		size = V(0.35, 0.3, 0.35),
		joint = V(0.6, 0.7, -0.55),
		color = "eye",
		neon = true,
	}, parts)
	-- Cuerpo: segmentos que se achican hacia la cola, apoyados en el suelo, con curva en S.
	local widths = { 1.5, 1.45, 1.35, 1.2, 1.05, 0.9, 0.7, 0.5 }
	local prev, prevH, prevLen = "Head", 1.1, 2.1
	for i, w in widths do
		local h = w * 0.8
		local len = 1.8
		local name = "Seg" .. i
		table.insert(parts, {
			name = name,
			parent = prev,
			size = V(w, h, len),
			joint = V(0, -(prevH - h) / 2, prevLen / 2),
			pivot = V(0, 0, -len / 2),
			rot = V(0, if i == 1 then 0 else (if i % 4 < 2 then 22 else -22), 0),
			color = if i % 2 == 0 then "light" else "body",
		})
		prev, prevH, prevLen = name, h, len
	end
	return {
		name = "Serpentino",
		palette = {
			body = Color3.fromRGB(78, 140, 138),
			light = Color3.fromRGB(122, 184, 170),
			dark = Color3.fromRGB(40, 82, 86),
			eye = Color3.fromRGB(255, 110, 210),
			socket = Color3.fromRGB(24, 46, 50),
			tooth = Color3.fromRGB(244, 238, 220),
		},
		parts = parts,
	}
end

return {
	Cuadrupedo = fromData(require(script.Parent.Data.Cuadrupedo) :: any, Textures.Atlas.Cuadrupedo),
	Musgo = fromData(require(script.Parent.Data.Musgo) :: any, Textures.Atlas.Musgo),
	HuevoMusgo = fromData(require(script.Parent.Data.HuevoMusgo) :: any, Textures.Atlas.HuevoMusgo),
	Grieta = fromData(require(script.Parent.Data.Grieta) :: any, Textures.Atlas.Grieta),
	HuevoGrieta = fromData(require(script.Parent.Data.HuevoGrieta) :: any, Textures.Atlas.HuevoGrieta),
	Bipedo = bipedo(),
	Serpentino = serpentino(),
}
