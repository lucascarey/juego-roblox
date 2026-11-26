--!strict
-- Zona de pruebas tipo zoo: baseplate plano con un corral por especie (pasto con desniveles para
-- probar cómo las patas se adaptan al terreno) con huevo, cría, joven y adulta adentro.
-- Especie nueva = una entrada más en PENS.
-- Se corre en modo edición (desde Studio / MCP): ZooBuilder.build().

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CreatureBuilder = require(ReplicatedStorage.Shared.Creatures.CreatureBuilder)
local Species = require(ReplicatedStorage.Shared.Creatures.Species)

local ZooBuilder = {}

local V = Vector3.new
local VOXEL = 4

-- Corrales: centro y medidas en studs (el piso de afuera está a y = 0).
local PEN_SIZE = V(160, 0, 120)
type Pen = {
	species: string,
	egg: string,
	center: Vector3,
	group: string,
	padColors: { Color3 }, -- cría, joven, adulta
	seed: number, -- cambia las lomas de cada corral
}
local PENS: { Pen } = {
	{
		species = "Musgo",
		egg = "HuevoMusgo",
		center = V(0, 0, 80),
		group = "Familia1",
		padColors = { Color3.fromRGB(250, 196, 214), Color3.fromRGB(240, 150, 180), Color3.fromRGB(214, 112, 150) },
		seed = 0.3,
	},
	{
		species = "Grieta",
		egg = "HuevoGrieta",
		center = V(190, 0, 80),
		group = "Familia2",
		padColors = { Color3.fromRGB(226, 150, 140), Color3.fromRGB(196, 100, 92), Color3.fromRGB(156, 62, 58) },
		seed = 4.7,
	},
}
local EDGE = 12 -- franja junto al cerco que queda plana
local FLOOR_DEPTH = 12

local function folder(name: string): Folder
	local old = workspace:FindFirstChild(name)
	if old then
		old:Destroy()
	end
	local f = Instance.new("Folder")
	f.Name = name
	f.Parent = workspace
	return f
end

-- Altura del pasto dentro del corral: lomas suaves, un par de montículos y un escalón,
-- todo bajando a 0 cerca del cerco.
local function height(pen: Pen, x: number, z: number): number
	local lx, lz = x - pen.center.X, z - pen.center.Z
	local hx, hz = PEN_SIZE.X / 2, PEN_SIZE.Z / 2
	local edgeDist = math.min(hx - math.abs(lx), hz - math.abs(lz))
	local fade = math.clamp((edgeDist - EDGE) / 18, 0, 1)
	fade = fade * fade * (3 - 2 * fade)
	local h = 4.5 * math.noise(lx / 46, lz / 46, pen.seed) + 2 * math.noise(lx / 17, lz / 17, pen.seed + 6.8)
	h += 7 * math.exp(-((lx + 38) ^ 2 + (lz - 18) ^ 2) / 300) -- loma
	h += 4 * math.exp(-((lx - 42) ^ 2 + (lz + 22) ^ 2) / 180) -- montículo
	-- Escalón (desnivel marcado) en una franja del corral, con borde en rampa empinada (4 studs)
	-- para que las crías también puedan subirlo.
	local inX = math.clamp(math.min(lx - 10, 60 - lx) / 4, 0, 1)
	local inZ = math.clamp((lz - 8) / 4, 0, 1)
	h += 2.5 * inX * inZ
	-- Sin pozos bajo el nivel del borde: abajo está el baseplate y se vería.
	return math.max(0, h) * fade
end

local function terrain(pen: Pen)
	local t = workspace.Terrain
	local hx, hz = PEN_SIZE.X / 2, PEN_SIZE.Z / 2
	local minC = V(pen.center.X - hx, -FLOOR_DEPTH, pen.center.Z - hz)
	local nx, nz = PEN_SIZE.X / VOXEL, PEN_SIZE.Z / VOXEL
	local ny = (FLOOR_DEPTH + 20) / VOXEL
	local mats, occ = {}, {}
	for ix = 1, nx do
		mats[ix], occ[ix] = {}, {}
		for iy = 1, ny do
			mats[ix][iy], occ[ix][iy] = {}, {}
		end
		for iz = 1, nz do
			local x = minC.X + (ix - 0.5) * VOXEL
			local z = minC.Z + (iz - 0.5) * VOXEL
			local h = height(pen, x, z)
			for iy = 1, ny do
				local bottom = minC.Y + (iy - 1) * VOXEL
				local o = math.clamp((h - bottom) / VOXEL, 0, 1)
				mats[ix][iy][iz] = if o > 0 then Enum.Material.Grass else Enum.Material.Air
				occ[ix][iy][iz] = o
			end
		end
	end
	local region = Region3.new(minC, minC + V(nx, ny, nz) * VOXEL)
	t:WriteVoxels(region, VOXEL, mats, occ)
end

local function block(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, mat: Enum.Material)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = mat
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

-- Baseplate: una losa grande; adentro de los corrales el pasto queda por encima y la tapa.
local function baseplate(parent: Instance)
	block(
		parent,
		"Baseplate",
		V(1024, 16, 1024),
		CFrame.new(95, -8, 80),
		Color3.fromRGB(99, 95, 98),
		Enum.Material.SmoothPlastic
	)
end

-- Cerco de madera en bloques: postes cada 8 studs y dos travesaños.
local function fence(parent: Instance, pen: Pen)
	local wood = Color3.fromRGB(122, 84, 52)
	local dark = Color3.fromRGB(92, 62, 38)
	local hx, hz = PEN_SIZE.X / 2, PEN_SIZE.Z / 2
	local c = pen.center
	local sides = {
		{ V(c.X - hx, 0, c.Z - hz), V(1, 0, 0), PEN_SIZE.X },
		{ V(c.X - hx, 0, c.Z + hz), V(1, 0, 0), PEN_SIZE.X },
		{ V(c.X - hx, 0, c.Z - hz), V(0, 0, 1), PEN_SIZE.Z },
		{ V(c.X + hx, 0, c.Z - hz), V(0, 0, 1), PEN_SIZE.Z },
	}
	for _, s in sides do
		local start, dir, len = s[1], s[2], s[3]
		for d = 0, len, 8 do
			block(parent, "Poste", V(1.5, 6, 1.5), CFrame.new(start + dir * d + V(0, 3, 0)), dark, Enum.Material.Wood)
		end
		local mid = start + dir * (len / 2)
		local size = if dir.X ~= 0 then V(len, 0.75, 0.6) else V(0.6, 0.75, len)
		block(parent, "Travesano", size, CFrame.new(mid + V(0, 2.25, 0)), wood, Enum.Material.Wood)
		block(parent, "Travesano", size, CFrame.new(mid + V(0, 4.5, 0)), wood, Enum.Material.Wood)
	end
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Include
rayParams.FilterDescendantsInstances = { workspace.Terrain }

local function groundAt(x: number, z: number): number
	local hit = workspace:Raycast(V(x, 200, z), V(0, -400, 0), rayParams)
	return if hit then hit.Position.Y else 0
end

-- Las cuatro etapas de la especie: una familia (madre adulta con su joven y su cría) junto al huevo.
-- La IA (server/Creatures/CreatureAI) maneja a las que tienen IA = true.
local function creatures(parent: Instance, pen: Pen)
	local c = pen.center
	local sp = (Species :: any)[pen.species]
	local list = {
		{ (Species :: any)[pen.egg], V(-12, 0, -8), 30, 1, nil },
		{ sp, V(-4, 0, -12), 200, 0, "Cria" },
		{ sp, V(10, 0, 0), 160, 0.5, "Joven" },
		{ sp, V(-20, 0, 14), 120, 1, "Madre" },
	}
	for _, s in list do
		local def, off, yaw, age, role = s[1], s[2], s[3], s[4], s[5]
		local x, z = c.X + off.X, c.Z + off.Z
		local cf = CFrame.new(x, groundAt(x, z), z) * CFrame.Angles(0, math.rad(yaw), 0)
		local model = CreatureBuilder.build(def, cf, { age = age })
		if role then
			model:SetAttribute("IA", true)
			model:SetAttribute("Grupo", pen.group)
			model:SetAttribute("Rol", role)
		end
		model.Parent = parent
	end
end

-- Carteles junto al cerco sur (del lado del spawn): cada uno convierte al jugador en una etapa y lo
-- deja adentro del corral. Los maneja server/Creatures/PlayAsCreature.
local function stagePads(parent: Instance, pen: Pen)
	local c = pen.center
	local fenceZ = c.Z - PEN_SIZE.Z / 2
	local stages = {
		{ "Cría", 0, pen.padColors[1] },
		{ "Joven", 0.5, pen.padColors[2] },
		{ "Adulta", 1, pen.padColors[3] },
	}
	for i, s in stages do
		local name, age, color = s[1], s[2], s[3]
		local x = c.X + (i - 2) * 8
		local pad = block(
			parent,
			"Etapa" .. pen.species .. name,
			V(5, 1, 5),
			CFrame.new(x, 0.5, fenceZ - 7),
			color,
			Enum.Material.SmoothPlastic
		)
		pad:SetAttribute("Especie", pen.species)
		pad:SetAttribute("Edad", age)
		-- Aparece adentro del corral, mirando hacia el centro (+Z).
		pad:SetAttribute("Aparece", CFrame.new(x, 0, fenceZ + 10) * CFrame.Angles(0, math.pi, 0))
		local prompt = Instance.new("ProximityPrompt")
		prompt.ActionText = "Jugar como " .. string.lower(name)
		prompt.ObjectText = pen.species
		prompt.KeyboardKeyCode = Enum.KeyCode.F
		prompt.MaxActivationDistance = 8
		prompt.RequiresLineOfSight = false
		prompt.Parent = pad
		local bb = Instance.new("BillboardGui")
		bb.Size = UDim2.fromOffset(160, 40)
		bb.StudsOffset = Vector3.new(0, 3, 0)
		bb.AlwaysOnTop = true
		bb.MaxDistance = 60
		bb.Parent = pad
		local text = Instance.new("TextLabel")
		text.Size = UDim2.fromScale(1, 1)
		text.BackgroundTransparency = 1
		text.Font = Enum.Font.GothamBold
		text.TextSize = 20
		text.TextColor3 = Color3.new(1, 1, 1)
		text.TextStrokeTransparency = 0.4
		text.Text = pen.species .. ": " .. name
		text.Parent = bb
	end
end

function ZooBuilder.build()
	-- Fuera lo anterior (entorno y criaturas de prueba viejas).
	for _, name in { "Arena", "Baseplate", "Zoo", "_Growth", "_Preview" } do
		local old = workspace:FindFirstChild(name)
		if old then
			old:Destroy()
		end
	end
	local root = folder("Zoo")
	workspace.Terrain:Clear()
	workspace.Terrain.Decoration = false -- sin pasto alto: tiene que verse dónde apoyan las patas
	for _, pen in PENS do
		terrain(pen)
	end
	task.wait() -- los rayos no ven el terreno nuevo hasta el próximo cuadro
	baseplate(root)
	local crit = Instance.new("Folder")
	crit.Name = "Criaturas"
	crit.Parent = root
	for _, pen in PENS do
		fence(root, pen)
		stagePads(root, pen)
		creatures(crit, pen)
	end

	-- Spawn entre los dos corrales, del lado de los carteles.
	local spawn = workspace:FindFirstChildOfClass("SpawnLocation")
	if spawn then
		local first, last = PENS[1].center, PENS[#PENS].center
		spawn.CFrame = CFrame.new((first.X + last.X) / 2, 0.5, first.Z - PEN_SIZE.Z / 2 - 16)
	end
end

return ZooBuilder
