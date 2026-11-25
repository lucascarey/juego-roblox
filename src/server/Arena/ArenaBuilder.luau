--!strict
-- Genera la arena de prueba: terreno con desnivel, barranco con río, ruinas, pinos low-poly,
-- rocas, flores y las 3 especies base. Se corre en Studio (modo edición) y el resultado se guarda en el place.
-- Es determinista (semilla fija): correrlo de nuevo reemplaza lo anterior.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CreatureBuilder = require(ReplicatedStorage.Shared.Creatures.CreatureBuilder)
local Species = require(ReplicatedStorage.Shared.Creatures.Species)

local ArenaBuilder = {}

local SEED = 42
local HALF = 124 -- la arena va de -HALF a +HALF en X y Z
local CELL = 4
local WATER_Y = 3
local BRIDGE_Z = 0

local terrain = workspace.Terrain
local V = Vector3.new

local function smoothstep(a: number, b: number, x: number): number
	local t = math.clamp((x - a) / (b - a), 0, 1)
	return t * t * (3 - 2 * t)
end

local function riverX(z: number): number
	return 56 + 8 * math.sin(z / 35)
end

function ArenaBuilder.heightAt(x: number, z: number): number
	local r = math.sqrt(x * x + z * z)
	local h = 10 + math.noise(x / 60, z / 60, 0.3) * 7 + math.noise(x / 18, z / 18, 1.7) * 2
	h = h + (10 - h) * (1 - smoothstep(30, 48, r)) -- claro central plano
	h = h + smoothstep(68, 104, r) * 38 * (0.75 + 0.25 * math.noise(x / 30, z / 30, 4.1)) -- acantilados alrededor
	local d = math.abs(x - riverX(z))
	h = h + (-3 - h) * (1 - smoothstep(5, 15, d)) -- barranco del río
	return h
end

local function getFolder(parent: Instance, name: string): Folder
	local f = parent:FindFirstChild(name)
	if f then
		f:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local function arenaFolder(): Instance
	local f = workspace:FindFirstChild("Arena")
	if not f then
		f = Instance.new("Folder")
		f.Name = "Arena"
		f.Parent = workspace
	end
	return f :: Instance
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Include
rayParams.FilterDescendantsInstances = { terrain }
rayParams.IgnoreWater = false

-- Altura real del suelo (incluye agua) en X/Z, o nil fuera del mapa.
local function groundAt(x: number, z: number): (number?, Enum.Material?)
	local hit = workspace:Raycast(V(x, 200, z), V(0, -300, 0), rayParams)
	if hit then
		return hit.Position.Y, hit.Material
	end
	return nil, nil
end

local function block(parent: Instance, size: Vector3, cf: CFrame, color: Color3, class: string?): BasePart
	local p = Instance.new((class or "Part") :: any) :: BasePart
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function vary(rng: Random, c: Color3, amount: number): Color3
	local h, s, v = c:ToHSV()
	return Color3.fromHSV(
		h,
		math.clamp(s + rng:NextNumber(-amount, amount), 0, 1),
		math.clamp(v + rng:NextNumber(-amount, amount), 0, 1)
	)
end

------------------------------------------------------------------------------------------------
-- Terreno

function ArenaBuilder.terrain()
	terrain:Clear()
	terrain:SetMaterialColor(Enum.Material.Grass, Color3.fromRGB(86, 140, 56))
	terrain:SetMaterialColor(Enum.Material.LeafyGrass, Color3.fromRGB(70, 122, 50))
	terrain.GrassLength = 0.2
	terrain:SetMaterialColor(Enum.Material.Rock, Color3.fromRGB(104, 112, 92))
	terrain:SetMaterialColor(Enum.Material.Slate, Color3.fromRGB(88, 96, 84))
	terrain:SetMaterialColor(Enum.Material.Ground, Color3.fromRGB(116, 92, 64))
	terrain:SetMaterialColor(Enum.Material.Mud, Color3.fromRGB(92, 76, 58))
	terrain.WaterColor = Color3.fromRGB(70, 150, 150)
	terrain.WaterTransparency = 0.6
	terrain.WaterWaveSize = 0.08
	terrain.WaterWaveSpeed = 6
	terrain.WaterReflectance = 0.4

	local H = ArenaBuilder.heightAt
	for x = -HALF, HALF, CELL do
		for z = -HALF, HALF, CELL do
			local h = H(x, z)
			local slope = math.max(math.abs(h - H(x + CELL, z)), math.abs(h - H(x, z + CELL)))
			local top: Enum.Material
			if slope > 4.5 then
				top = if h > 24 then Enum.Material.Slate else Enum.Material.Rock
			elseif h < WATER_Y + 1 then
				top = Enum.Material.Mud
			elseif math.noise(x / 25, z / 25, 9.2) > 0.25 then
				top = Enum.Material.LeafyGrass
			else
				top = Enum.Material.Grass
			end
			local bottom = -12
			terrain:FillBlock(
				CFrame.new(x, (bottom + h - 3) / 2, z),
				V(CELL, h - 3 - bottom, CELL),
				Enum.Material.Ground
			)
			terrain:FillBlock(CFrame.new(x, h - 1.5, z), V(CELL, 3, CELL), top)
			if h < WATER_Y then
				terrain:FillBlock(CFrame.new(x, (h + WATER_Y) / 2, z), V(CELL, WATER_Y - h, CELL), Enum.Material.Water)
			end
		end
		task.wait()
	end
	terrain.Decoration = true
end

------------------------------------------------------------------------------------------------
-- Pinos low-poly: tronco + 3 pirámides apiladas. Cada pirámide son 4 CornerWedge (una por cuadrante).

-- Esquina alta del CornerWedgePart en su espacio local (X, Z).
local WEDGE_APEX = V(1, 0, -1)

local function pyramid(parent: Instance, center: Vector3, base: number, height: number, yaw: number, color: Color3)
	local q = base / 2
	for _, s in { { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } } do
		local sx, sz = s[1], s[2]
		local inward = V(-sx, 0, -sz).Unit
		local best, bestDot = 0, -math.huge
		for k = 0, 3 do
			local dir = CFrame.Angles(0, k * math.pi / 2, 0):VectorToWorldSpace(WEDGE_APEX).Unit
			local d = dir:Dot(inward)
			if d > bestDot then
				best, bestDot = k, d
			end
		end
		local yawCf = CFrame.Angles(0, yaw, 0)
		local offset = yawCf:VectorToWorldSpace(V(sx * q / 2, 0, sz * q / 2))
		local cf = CFrame.new(center + offset + V(0, height / 2, 0)) * yawCf * CFrame.Angles(0, best * math.pi / 2, 0)
		block(parent, V(q, height, q), cf, color, "CornerWedgePart")
	end
end

local PINE_GREENS = { Color3.fromRGB(46, 108, 66), Color3.fromRGB(58, 126, 72), Color3.fromRGB(38, 92, 60) }
local TRUNK = Color3.fromRGB(96, 66, 46)

local function pine(parent: Instance, rng: Random, pos: Vector3, scale: number)
	local m = Instance.new("Model")
	m.Name = "Pino"
	local trunkH = 4 * scale
	block(m, V(1.2, trunkH + 1, 1.2) * V(scale, 1, scale), CFrame.new(pos + V(0, trunkH / 2 - 0.5, 0)), TRUNK)
	local green = PINE_GREENS[rng:NextInteger(1, #PINE_GREENS)]
	local y = trunkH
	local yaw = rng:NextNumber(0, math.pi / 2)
	for i, tier in { { 9, 7 }, { 7, 6 }, { 4.8, 5.5 } } do
		pyramid(m, pos + V(0, y, 0), tier[1] * scale, tier[2] * scale, yaw + i * math.pi / 4, vary(rng, green, 0.04))
		y += tier[2] * scale * 0.55
	end
	m.Parent = parent
end

------------------------------------------------------------------------------------------------
-- Rocas, arbustos, flores

local STONE = Color3.fromRGB(150, 158, 140)
local ROCK = Color3.fromRGB(128, 124, 116)
local MOSS = Color3.fromRGB(92, 150, 64)

local function rock(parent: Instance, rng: Random, pos: Vector3, size: number)
	local m = Instance.new("Model")
	m.Name = "Roca"
	local s = V(size * rng:NextNumber(0.8, 1.3), size * rng:NextNumber(0.5, 0.9), size * rng:NextNumber(0.8, 1.3))
	local rot = CFrame.Angles(rng:NextNumber(-0.3, 0.3), rng:NextNumber(0, math.pi), rng:NextNumber(-0.3, 0.3))
	local main = block(m, s, CFrame.new(pos + V(0, s.Y * 0.25, 0)) * rot, vary(rng, ROCK, 0.05))
	if rng:NextNumber() < 0.6 then
		block(m, V(s.X * 0.85, 0.35, s.Z * 0.85), main.CFrame * CFrame.new(0, s.Y / 2 + 0.1, 0), vary(rng, MOSS, 0.05))
	end
	for _ = 1, rng:NextInteger(0, 2) do
		local ss = size * rng:NextNumber(0.25, 0.45)
		local off = V(rng:NextNumber(-1, 1), 0, rng:NextNumber(-1, 1)).Unit * (size * 0.8)
		block(
			m,
			V(ss, ss * 0.7, ss),
			CFrame.new(pos + off + V(0, ss * 0.2, 0)) * CFrame.Angles(0, rng:NextNumber(0, 3), 0.2),
			vary(rng, ROCK, 0.06)
		)
	end
	m.Parent = parent
end

local function bush(parent: Instance, rng: Random, pos: Vector3)
	local m = Instance.new("Model")
	m.Name = "Arbusto"
	for _ = 1, rng:NextInteger(3, 5) do
		local s = rng:NextNumber(1.6, 3)
		local off = V(rng:NextNumber(-1.4, 1.4), s * 0.35, rng:NextNumber(-1.4, 1.4))
		block(
			m,
			V(s, s * 0.8, s),
			CFrame.new(pos + off) * CFrame.Angles(0, rng:NextNumber(0, 3), 0),
			vary(rng, Color3.fromRGB(70, 138, 58), 0.06)
		)
	end
	m.Parent = parent
end

local FLOWER_COLORS = {
	Color3.fromRGB(150, 104, 226),
	Color3.fromRGB(244, 206, 64),
	Color3.fromRGB(246, 244, 236),
	Color3.fromRGB(236, 128, 170),
}

local function flowerPatch(parent: Instance, rng: Random, pos: Vector3)
	local m = Instance.new("Model")
	m.Name = "Flores"
	local color = FLOWER_COLORS[rng:NextInteger(1, #FLOWER_COLORS)]
	for _ = 1, rng:NextInteger(6, 11) do
		local x, z = pos.X + rng:NextNumber(-3, 3), pos.Z + rng:NextNumber(-3, 3)
		local y = groundAt(x, z)
		if y then
			local stemH = rng:NextNumber(0.6, 1.4)
			local stem = block(m, V(0.14, stemH, 0.14), CFrame.new(x, y + stemH / 2, z), Color3.fromRGB(70, 130, 50))
			stem.CanCollide = false
			stem.CastShadow = false
			local petal = block(
				m,
				V(0.55, 0.3, 0.55),
				CFrame.new(x, y + stemH, z) * CFrame.Angles(0, rng:NextNumber(0, 3), 0),
				vary(rng, color, 0.05)
			)
			petal.CanCollide = false
			petal.CastShadow = false
		end
	end
	m.Parent = parent
end

------------------------------------------------------------------------------------------------
-- Ruinas

local function vine(parent: Instance, rng: Random, top: Vector3, maxLen: number)
	local len = rng:NextNumber(1, math.max(1.2, maxLen))
	local p = block(
		parent,
		V(0.22, len, 0.22),
		CFrame.new(top - V(0, len / 2, 0)),
		vary(rng, Color3.fromRGB(64, 132, 52), 0.05)
	)
	p.CanCollide = false
end

local function pillar(parent: Instance, rng: Random, base: Vector3, blocks: number, mossy: boolean)
	local m = Instance.new("Model")
	m.Name = "Pilar"
	local y = base.Y
	local top = base
	for i = 1, blocks do
		local w = 3 - i * 0.08
		local h = rng:NextNumber(2.2, 3)
		local cf = CFrame.new(base.X + rng:NextNumber(-0.2, 0.2), y + h / 2, base.Z + rng:NextNumber(-0.2, 0.2))
			* CFrame.Angles(0, rng:NextNumber(-0.12, 0.12), rng:NextNumber(-0.03, 0.03))
		block(m, V(w, h, w), cf, vary(rng, STONE, 0.05))
		y += h
		top = V(cf.X, y, cf.Z)
	end
	if mossy then
		block(m, V(2.9, 0.3, 2.9), CFrame.new(top + V(0, 0.15, 0)), vary(rng, MOSS, 0.05))
		for _ = 1, rng:NextInteger(1, 3) do
			vine(
				m,
				rng,
				top + V(rng:NextNumber(-1.2, 1.2), 0, if rng:NextNumber() < 0.5 then -1.62 else 1.62),
				(y - base.Y) * 0.5
			)
		end
	end
	m.Parent = parent
	return top
end

local function ruins(parent: Instance, rng: Random)
	-- Anillo de pilares alrededor del claro, algunos rotos.
	for i = 0, 9 do
		local a = i / 10 * math.pi * 2
		local x, z = math.cos(a) * 26, math.sin(a) * 26
		local y = groundAt(x, z)
		if y then
			local broken = rng:NextNumber() < 0.4
			pillar(
				parent,
				rng,
				V(x, y - 0.3, z),
				if broken then rng:NextInteger(1, 2) else rng:NextInteger(3, 4),
				rng:NextNumber() < 0.7
			)
			if broken then
				local fx, fz = x + rng:NextNumber(-4, 4), z + rng:NextNumber(-4, 4)
				local fy = groundAt(fx, fz)
				if fy then
					block(
						parent,
						V(3, 2.6, 3),
						CFrame.new(fx, fy + 1, fz) * CFrame.Angles(rng:NextNumber(-0.5, 0.5), rng:NextNumber(0, 3), 1.2),
						vary(rng, STONE, 0.05)
					)
				end
			end
		end
	end

	-- Arco al norte del claro.
	local ax, az = 0, 34
	local ay = groundAt(ax, az) or 10
	local tl = pillar(parent, rng, V(ax - 5, ay - 0.3, az), 4, true)
	local tr = pillar(parent, rng, V(ax + 5, ay - 0.3, az), 4, true)
	local topY = math.max(tl.Y, tr.Y)
	local lintel = block(parent, V(14, 2.4, 3), CFrame.new(ax, topY + 1.2, az), vary(rng, STONE, 0.04))
	block(parent, V(13, 0.3, 2.8), lintel.CFrame * CFrame.new(0, 1.35, 0), vary(rng, MOSS, 0.05))
	for _ = 1, 5 do
		vine(parent, rng, V(ax + rng:NextNumber(-6, 6), topY, az - 1.6), 5)
	end

	-- Muro roto al oeste.
	for i = 0, 5 do
		local x, z = -36 + rng:NextNumber(-0.3, 0.3), -10 + i * 3.1
		local y = groundAt(x, z)
		if y then
			for j = 1, rng:NextInteger(1, 3) do
				block(
					parent,
					V(3, 2.4, 3),
					CFrame.new(x, y + j * 2.4 - 1.4, z) * CFrame.Angles(0, rng:NextNumber(-0.1, 0.1), 0),
					vary(rng, STONE, 0.05)
				)
			end
		end
	end

	-- Camino de losas desde el puente hasta el centro.
	for t = 0, 1, 0.045 do
		local x = 8 + (riverX(BRIDGE_Z) - 16 - 8) * t + rng:NextNumber(-1, 1)
		local z = BRIDGE_Z + math.sin(t * 3) * 4 + rng:NextNumber(-1, 1)
		local y = groundAt(x, z)
		if y then
			block(
				parent,
				V(rng:NextNumber(2.4, 3.4), 0.5, rng:NextNumber(2.4, 3.4)),
				CFrame.new(x, y + 0.05, z) * CFrame.Angles(0, rng:NextNumber(0, 1.5), 0),
				vary(rng, STONE, 0.06)
			)
		end
	end
end

local function bridge(parent: Instance, rng: Random)
	local cx = riverX(BRIDGE_Z)
	local x0, x1 = cx - 16, cx + 16
	local y0 = groundAt(x0, BRIDGE_Z) or 10
	local y1 = groundAt(x1, BRIDGE_Z) or 10
	local deckY = math.max(y0, y1) + 0.6
	local m = Instance.new("Model")
	m.Name = "Puente"
	for x = x0, x1, 3.2 do
		if rng:NextNumber() > 0.07 then
			block(
				m,
				V(3.1, 1.4, 6),
				CFrame.new(x, deckY + rng:NextNumber(-0.15, 0.15), BRIDGE_Z)
					* CFrame.Angles(0, rng:NextNumber(-0.05, 0.05), 0),
				vary(rng, STONE, 0.05)
			)
			if rng:NextNumber() < 0.35 then
				vine(m, rng, V(x, deckY - 0.7, BRIDGE_Z + (if rng:NextNumber() < 0.5 then -3.1 else 3.1)), 6)
			end
		end
	end
	for _, z in { BRIDGE_Z - 3.2, BRIDGE_Z + 3.2 } do
		for x = x0, x1, 6.4 do
			block(m, V(1, 1.6, 1), CFrame.new(x, deckY + 1.5, z), vary(rng, STONE, 0.05))
		end
	end
	m.Parent = parent
end

------------------------------------------------------------------------------------------------

local function scatter(
	rng: Random,
	n: number,
	ok: (x: number, z: number, y: number, mat: Enum.Material) -> boolean,
	place: (Vector3) -> ()
)
	local placed, tries = 0, 0
	while placed < n and tries < n * 20 do
		tries += 1
		local x, z = rng:NextNumber(-HALF + 6, HALF - 6), rng:NextNumber(-HALF + 6, HALF - 6)
		local y, mat = groundAt(x, z)
		if y and mat and mat ~= Enum.Material.Water and ok(x, z, y, mat) then
			place(V(x, y, z))
			placed += 1
			if placed % 10 == 0 then
				task.wait()
			end
		end
	end
end

local function isGrass(mat: Enum.Material): boolean
	return mat == Enum.Material.Grass or mat == Enum.Material.LeafyGrass
end

local function nearRiver(x: number, z: number): boolean
	return math.abs(x - riverX(z)) < 17
end

function ArenaBuilder.props()
	local rng = Random.new(SEED)
	local root = arenaFolder()

	local trees = getFolder(root, "Pinos")
	scatter(rng, 85, function(x, z, _y, mat)
		local r = math.sqrt(x * x + z * z)
		return r > 40 and isGrass(mat) and not nearRiver(x, z)
	end, function(p)
		pine(trees, rng, p, rng:NextNumber(0.8, 1.35))
	end)

	local rocks = getFolder(root, "Rocas")
	scatter(rng, 45, function(x, z)
		return math.sqrt(x * x + z * z) > 20 or nearRiver(x, z)
	end, function(p)
		rock(rocks, rng, p, rng:NextNumber(2, 7))
	end)

	local bushes = getFolder(root, "Arbustos")
	scatter(rng, 70, function(_x, _z, _y, mat)
		return isGrass(mat)
	end, function(p)
		bush(bushes, rng, p)
	end)

	local flowers = getFolder(root, "Flores")
	scatter(rng, 80, function(x, z, _y, mat)
		return isGrass(mat) and math.sqrt(x * x + z * z) < 70
	end, function(p)
		flowerPatch(flowers, rng, p)
	end)

	local ruinsFolder = getFolder(root, "Ruinas")
	ruins(ruinsFolder, rng)
	bridge(ruinsFolder, rng)
end

function ArenaBuilder.creatures()
	local folder = getFolder(arenaFolder(), "Criaturas")
	local spots = {
		{ Species.Cuadrupedo, V(-9, 0, 4), 20 },
		{ Species.Bipedo, V(0, 0, 1), 0 },
		{ Species.Serpentino, V(9, 0, 4), -25 },
	}
	for _, s in spots do
		local def, pos, yaw = s[1], s[2], s[3]
		local y = groundAt(pos.X, pos.Z) or 10
		local model = CreatureBuilder.build(def, CFrame.new(pos.X, y, pos.Z) * CFrame.Angles(0, math.rad(yaw), 0))
		model.Parent = folder
	end
end

-- Quita la base del template y deja el spawn en el claro.
function ArenaBuilder.cleanupTemplate()
	local base = workspace:FindFirstChild("Baseplate")
	if base then
		base:Destroy()
	end
	local spawn = workspace:FindFirstChildOfClass("SpawnLocation")
	if spawn then
		local y = groundAt(0, -18) or 10
		spawn.CFrame = CFrame.new(0, y + 0.5, -18)
		spawn.Transparency = 1 -- el spawn no tiene que verse en la arena
		local decal = spawn:FindFirstChildOfClass("Decal")
		if decal then
			decal:Destroy()
		end
	end
end

return ArenaBuilder
