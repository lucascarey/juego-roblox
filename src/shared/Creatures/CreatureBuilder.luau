--!strict
-- Arma una criatura de piezas rígidas (cajas) unidas por Motor6D a partir de una definición de especie.
-- Crecimiento: con opts.age (0 = cría, 1 = adulto) la criatura se achica y cada pieza toma
-- su proporción de cría (babyScale), interpolando de forma continua. opts.size es el tamaño individual.

export type PartDef = {
	name: string,
	parent: string, -- "Root" o el nombre de otra pieza ya definida antes
	size: Vector3,
	joint: Vector3, -- punto de la articulación en el espacio de la pieza padre
	pivot: Vector3?, -- mismo punto en el espacio de esta pieza (default: centro)
	rot: Vector3?, -- rotación de la articulación en grados (X, Y, Z)
	color: string, -- clave de la paleta
	neon: boolean?,
	flat: boolean?, -- sin textura (dientes, ojos, detalles chicos)
	faces: { [string]: { number } }?, -- recorte del atlas por cara: {u, v, ancho, alto} en studs
	babyScale: number?, -- tamaño relativo de la pieza en la cría (cabeza > 1, patas < 1); default 1
}

export type SpeciesDef = {
	name: string,
	palette: { [string]: Color3 },
	parts: { PartDef },
	atlas: string?,
	atlasStuds: Vector2?,
	babySize: number?, -- tamaño general de la cría respecto del adulto; default 0.4
}

export type BuildOptions = {
	age: number?, -- 0 = cría, 1 = adulto (default)
	size: number?, -- tamaño individual, ej. 0.9 a 1.12 (default 1)
}

local Textures = require(script.Parent.Parent.Textures)

local CreatureBuilder = {}

local FACES = Enum.NormalId:GetEnumItems()

-- Cubre las 6 caras con la textura pixelada teñida del color de la pieza.
-- El desfase por pieza evita que todas las manchas queden alineadas.
local function applySkin(part: BasePart, color: Color3, index: number, scale: number)
	for _, face in FACES do
		local t = Instance.new("Texture")
		t.Texture = Textures.Piel
		t.Face = face
		t.Color3 = color
		t.StudsPerTileU = Textures.STUDS_PER_TILE * scale
		t.StudsPerTileV = Textures.STUDS_PER_TILE * scale
		t.OffsetStudsU = (index * 1.25) % Textures.STUDS_PER_TILE * scale
		t.OffsetStudsV = (index * 2.5) % Textures.STUDS_PER_TILE * scale
		t.Parent = part
	end
end

-- Cada cara muestra su recorte del atlas de la especie: el tile ocupa todo el atlas
-- y el desfase lleva la esquina del recorte a la esquina de la cara.
local function applyAtlas(
	part: BasePart,
	faces: { [string]: { number } },
	atlas: string,
	atlasStuds: Vector2,
	scale: number
)
	for faceName, r in faces do
		local t = Instance.new("Texture")
		t.Texture = atlas
		t.Face = (Enum.NormalId :: any)[faceName]
		t.StudsPerTileU = atlasStuds.X * scale
		t.StudsPerTileV = atlasStuds.Y * scale
		t.OffsetStudsU = r[1] * scale
		t.OffsetStudsV = r[2] * scale
		t.Parent = part
	end
end

local function rad(v: Vector3): CFrame
	return CFrame.Angles(math.rad(v.X), math.rad(v.Y), math.rad(v.Z))
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- Escala de una pieza para una edad: tamaño general de la etapa por su proporción de cría.
function CreatureBuilder.partScale(def: SpeciesDef, p: PartDef?, age: number, size: number): number
	local overall = lerp(def.babySize or 0.4, 1, age) * size
	return overall * lerp(if p then p.babyScale or 1 else 1, 1, age)
end

function CreatureBuilder.build(def: SpeciesDef, at: CFrame, opts: BuildOptions?): Model
	local age = math.clamp(if opts and opts.age then opts.age else 1, 0, 1)
	local size = if opts and opts.size then opts.size else 1

	local model = Instance.new("Model")
	model.Name = def.name
	model:SetAttribute("Age", age)
	model:SetAttribute("Size", size)

	local root = Instance.new("Part")
	root.Name = "Root"
	root.Size = Vector3.new(1, 1, 1)
	root.Transparency = 1
	root.Anchored = true
	root.CanCollide = false
	root.CFrame = at
	root.Parent = model
	model.PrimaryPart = root

	local byName: { [string]: BasePart } = { Root = root }
	local scaleOf: { [string]: number } = { Root = CreatureBuilder.partScale(def, nil, age, size) }
	for i, p in def.parts do
		local parentPart = byName[p.parent]
		assert(parentPart, `{def.name}: la pieza "{p.name}" usa un padre inexistente "{p.parent}"`)
		local color = def.palette[p.color]
		assert(color, `{def.name}: color "{p.color}" no está en la paleta`)
		local s = CreatureBuilder.partScale(def, p, age, size)
		local ps = scaleOf[p.parent]

		local part = Instance.new("Part")
		part.Name = p.name
		part.Size = p.size * s
		part.Color = color
		part.Material = if p.neon then Enum.Material.Neon else Enum.Material.SmoothPlastic
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.CanCollide = false
		part.Massless = true
		part.CastShadow = not p.neon
		if p.faces and def.atlas and def.atlasStuds then
			applyAtlas(part, p.faces, def.atlas, def.atlasStuds, s)
		elseif not p.neon and not p.flat then
			applySkin(part, color, i, s)
		end

		-- La articulación se escala con el padre (está en su espacio) y el pivote con la pieza.
		local c0 = CFrame.new(p.joint * ps) * (if p.rot then rad(p.rot) else CFrame.identity)
		local c1 = CFrame.new((p.pivot or Vector3.zero) * s)
		part.CFrame = parentPart.CFrame * c0 * c1:Inverse()
		part.Parent = model

		local motor = Instance.new("Motor6D")
		motor.Name = p.name
		motor.Part0 = parentPart
		motor.Part1 = part
		motor.C0 = c0
		motor.C1 = c1
		motor.Parent = parentPart

		byName[p.name] = part
		scaleOf[p.name] = s
	end

	-- Con proporciones de cría las patas no siempre llegan justo al piso: apoyamos la criatura.
	local lowest = math.huge
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d ~= root then
			local cf, half = d.CFrame, d.Size / 2
			for _, sx in { -1, 1 } do
				for _, sy in { -1, 1 } do
					for _, sz in { -1, 1 } do
						lowest = math.min(lowest, cf:PointToWorldSpace(half * Vector3.new(sx, sy, sz)).Y)
					end
				end
			end
		end
	end
	if lowest < math.huge then
		model:PivotTo(model:GetPivot() + Vector3.new(0, at.Position.Y - lowest, 0))
	end

	return model
end

return CreatureBuilder
