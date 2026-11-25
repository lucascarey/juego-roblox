--!strict
-- Arma una criatura de piezas rígidas (cajas) unidas por Motor6D a partir de una definición de especie.

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
}

export type SpeciesDef = {
	name: string,
	palette: { [string]: Color3 },
	parts: { PartDef },
	atlas: string?,
	atlasStuds: Vector2?,
}

local Textures = require(script.Parent.Parent.Textures)

local CreatureBuilder = {}

local FACES = Enum.NormalId:GetEnumItems()

-- Cubre las 6 caras con la textura pixelada teñida del color de la pieza.
-- El desfase por pieza evita que todas las manchas queden alineadas.
local function applySkin(part: BasePart, color: Color3, index: number)
	for _, face in FACES do
		local t = Instance.new("Texture")
		t.Texture = Textures.Piel
		t.Face = face
		t.Color3 = color
		t.StudsPerTileU = Textures.STUDS_PER_TILE
		t.StudsPerTileV = Textures.STUDS_PER_TILE
		t.OffsetStudsU = (index * 1.25) % Textures.STUDS_PER_TILE
		t.OffsetStudsV = (index * 2.5) % Textures.STUDS_PER_TILE
		t.Parent = part
	end
end

-- Cada cara muestra su recorte del atlas de la especie: el tile ocupa todo el atlas
-- y el desfase lleva la esquina del recorte a la esquina de la cara.
local function applyAtlas(part: BasePart, faces: { [string]: { number } }, atlas: string, atlasStuds: Vector2)
	for faceName, r in faces do
		local t = Instance.new("Texture")
		t.Texture = atlas
		t.Face = (Enum.NormalId :: any)[faceName]
		t.StudsPerTileU = atlasStuds.X
		t.StudsPerTileV = atlasStuds.Y
		t.OffsetStudsU = r[1]
		t.OffsetStudsV = r[2]
		t.Parent = part
	end
end

local function rad(v: Vector3): CFrame
	return CFrame.Angles(math.rad(v.X), math.rad(v.Y), math.rad(v.Z))
end

function CreatureBuilder.build(def: SpeciesDef, at: CFrame): Model
	local model = Instance.new("Model")
	model.Name = def.name

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
	for i, p in def.parts do
		local parentPart = byName[p.parent]
		assert(parentPart, `{def.name}: la pieza "{p.name}" usa un padre inexistente "{p.parent}"`)
		local color = def.palette[p.color]
		assert(color, `{def.name}: color "{p.color}" no está en la paleta`)

		local part = Instance.new("Part")
		part.Name = p.name
		part.Size = p.size
		part.Color = color
		part.Material = if p.neon then Enum.Material.Neon else Enum.Material.SmoothPlastic
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.CanCollide = false
		part.Massless = true
		part.CastShadow = not p.neon
		if p.faces and def.atlas and def.atlasStuds then
			applyAtlas(part, p.faces, def.atlas, def.atlasStuds)
		elseif not p.neon and not p.flat then
			applySkin(part, color, i)
		end

		local c0 = CFrame.new(p.joint) * (if p.rot then rad(p.rot) else CFrame.identity)
		local c1 = CFrame.new(p.pivot or Vector3.zero)
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
	end

	return model
end

return CreatureBuilder
