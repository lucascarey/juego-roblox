--!strict
-- Genera la arena de prueba según la referencia de ambiente: claro con ruinas en primer plano,
-- un barranco profundo con paredes de tierra y enredaderas, un puente de piedra que lo cruza,
-- la otra orilla con un arco y pinos, y montañas lejanas en la neblina.
-- Se corre en Studio (modo edición) y el resultado se guarda en el place.
-- Es determinista (semilla fija): correrlo de nuevo reemplaza lo anterior.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CreatureBuilder = require(ReplicatedStorage.Shared.Creatures.CreatureBuilder)
local Species = require(ReplicatedStorage.Shared.Creatures.Species)

local ArenaBuilder = {}

local SEED = 42
local HALF = 124 -- zona jugable: de -HALF a +HALF en X y Z (celdas de 4 studs)
local FAR = 480 -- las montañas lejanas llegan hasta acá (celdas de 16 studs)
local CELL = 4
local FAR_CELL = 8
local WATER_Y = -9
local BRIDGE_X = 0

local terrain = workspace.Terrain
local V = Vector3.new

local function smoothstep(a: number, b: number, x: number): number
	local t = math.clamp((x - a) / (b - a), 0, 1)
	return t * t * (3 - 2 * t)
end

-- Línea central del barranco: corre de oeste a este, al norte del claro.
local function ravineZ(x: number): number
	return 50 + 7 * math.sin(x / 32)
end

function ArenaBuilder.heightAt(x: number, z: number): number
	local r = math.sqrt(x * x + z * z)
	local h = 10 + math.noise(x / 70, z / 70, 0.3) * 6 + math.noise(x / 20, z / 20, 1.7) * 1.5
	h = h + (10 - h) * (1 - smoothstep(28, 44, r)) -- claro central plano
	h = h + smoothstep(0, 30, z - ravineZ(x)) * 12 -- la otra orilla es más alta
	h = h + smoothstep(110, 330, r) * (70 + 50 * math.noise(x / 90, z / 90, 6.2)) -- montañas lejanas
	local d = math.abs(z - ravineZ(x))
	h = h + (-14 - h) * (1 - smoothstep(11, 12.5, d)) -- barranco ancho, de paredes casi verticales
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
	local hit = workspace:Raycast(V(x, 400, z), V(0, -500, 0), rayParams)
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

local function deco(parent: Instance, size: Vector3, cf: CFrame, color: Color3): BasePart
	local p = block(parent, size, cf, color)
	p.CanCollide = false
	p.CastShadow = false
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

local function fillColumn(x: number, z: number, cell: number, h: number, slope: number)
	local top: Enum.Material
	if slope > cell * 1.1 then
		top = if h < 2 then Enum.Material.Mud else Enum.Material.Ground -- paredes de tierra
	elseif h > 60 and slope > cell * 0.5 then
		top = Enum.Material.Rock
	elseif h < WATER_Y + 1.5 then
		top = Enum.Material.Mud
	elseif math.noise(x / 25, z / 25, 9.2) > 0.2 then
		top = Enum.Material.LeafyGrass
	else
		top = Enum.Material.Grass
	end
	local bottom = -26
	terrain:FillBlock(CFrame.new(x, (bottom + h - 3) / 2, z), V(cell, h - 3 - bottom, cell), Enum.Material.Ground)
	terrain:FillBlock(CFrame.new(x, h - 1.5, z), V(cell, 3, cell), top)
	if h < WATER_Y then
		terrain:FillBlock(CFrame.new(x, (h + WATER_Y) / 2, z), V(cell, WATER_Y - h, cell), Enum.Material.Water)
	end
end

function ArenaBuilder.terrain()
	terrain:Clear()
	terrain:SetMaterialColor(Enum.Material.Grass, Color3.fromRGB(118, 168, 52))
	terrain:SetMaterialColor(Enum.Material.LeafyGrass, Color3.fromRGB(96, 150, 48))
	terrain:SetMaterialColor(Enum.Material.Ground, Color3.fromRGB(128, 96, 66))
	terrain:SetMaterialColor(Enum.Material.Mud, Color3.fromRGB(78, 62, 48))
	terrain:SetMaterialColor(Enum.Material.Rock, Color3.fromRGB(112, 116, 104))
	terrain.GrassLength = 0.3
	terrain.WaterColor = Color3.fromRGB(64, 130, 120)
	terrain.WaterTransparency = 0.5
	terrain.WaterWaveSize = 0.06
	terrain.WaterWaveSpeed = 5
	terrain.WaterReflectance = 0.3

	local H = ArenaBuilder.heightAt
	for x = -HALF, HALF, CELL do
		for z = -HALF, HALF, CELL do
			local h = H(x, z)
			local slope = math.max(math.abs(h - H(x + CELL, z)), math.abs(h - H(x, z + CELL)))
			fillColumn(x, z, CELL, h, slope)
		end
		task.wait()
	end
	-- Montañas lejanas, con celdas más grandes (fuera de la zona jugable).
	for x = -FAR, FAR, FAR_CELL do
		for z = -FAR, FAR, FAR_CELL do
			if math.abs(x) > HALF + 2 or math.abs(z) > HALF + 2 then
				local h = H(x, z)
				local slope = math.max(math.abs(h - H(x + FAR_CELL, z)), math.abs(h - H(x, z + FAR_CELL)))
				fillColumn(x, z, FAR_CELL, h, slope * 0.6)
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

local PINE_GREENS = { Color3.fromRGB(40, 98, 64), Color3.fromRGB(52, 116, 70), Color3.fromRGB(34, 84, 58) }
local TRUNK = Color3.fromRGB(90, 62, 44)

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

-- Árbol seco: tronco oscuro con ramas en ángulo, como el de la referencia.
local function deadTree(parent: Instance, rng: Random, pos: Vector3)
	local m = Instance.new("Model")
	m.Name = "ArbolSeco"
	local bark = Color3.fromRGB(70, 54, 46)
	local h = rng:NextNumber(10, 14)
	block(m, V(1.3, h, 1.3), CFrame.new(pos + V(0, h / 2 - 0.5, 0)) * CFrame.Angles(0, 0, 0.06), bark)
	for i = 1, 7 do
		local y = h * rng:NextNumber(0.45, 0.95)
		local len = rng:NextNumber(3, 6) * (1.1 - y / h * 0.5)
		local yaw = (i / 7) * math.pi * 2 + rng:NextNumber(-0.4, 0.4)
		local tilt = rng:NextNumber(0.5, 1.0)
		local cf = CFrame.new(pos + V(0, y, 0))
			* CFrame.Angles(0, yaw, 0)
			* CFrame.Angles(0, 0, -tilt)
			* CFrame.new(0, len / 2, 0)
		local branch = block(m, V(0.45, len, 0.45), cf, vary(rng, bark, 0.04))
		local twig = rng:NextNumber(1.2, 2.4)
		block(
			m,
			V(0.25, twig, 0.25),
			branch.CFrame * CFrame.new(0, len / 2, 0) * CFrame.Angles(0, 0, 0.7) * CFrame.new(0, twig / 2, 0),
			bark
		)
	end
	m.Parent = parent
end

------------------------------------------------------------------------------------------------
-- Piedras, arbustos, flores

local STONE = Color3.fromRGB(140, 148, 134)
local MOSS = Color3.fromRGB(104, 160, 56)
local VINE = Color3.fromRGB(70, 136, 48)

-- Bloque de piedra suelto, medio enterrado y torcido, a veces con musgo arriba.
local function stoneBlock(parent: Instance, rng: Random, pos: Vector3, size: number)
	local m = Instance.new("Model")
	m.Name = "Piedra"
	local s = V(size * rng:NextNumber(1, 1.6), size * rng:NextNumber(0.5, 0.9), size * rng:NextNumber(0.7, 1.1))
	local rot = CFrame.Angles(rng:NextNumber(-0.25, 0.25), rng:NextNumber(0, math.pi), rng:NextNumber(-0.25, 0.25))
	local main = block(m, s, CFrame.new(pos + V(0, s.Y * 0.3, 0)) * rot, vary(rng, STONE, 0.05))
	if rng:NextNumber() < 0.5 then
		deco(m, V(s.X * 0.8, 0.3, s.Z * 0.8), main.CFrame * CFrame.new(0, s.Y / 2 + 0.1, 0), vary(rng, MOSS, 0.05))
	end
	m.Parent = parent
end

local function bush(parent: Instance, rng: Random, pos: Vector3)
	local m = Instance.new("Model")
	m.Name = "Arbusto"
	for _ = 1, rng:NextInteger(3, 6) do
		local s = rng:NextNumber(1.4, 3.2)
		local off = V(rng:NextNumber(-1.6, 1.6), s * 0.35, rng:NextNumber(-1.6, 1.6))
		block(
			m,
			V(s, s * 0.8, s),
			CFrame.new(pos + off) * CFrame.Angles(0, rng:NextNumber(0, 3), 0),
			vary(rng, Color3.fromRGB(78, 140, 50), 0.07)
		)
	end
	m.Parent = parent
end

local FLOWER_COLORS = {
	Color3.fromRGB(246, 244, 236),
	Color3.fromRGB(246, 210, 60),
	Color3.fromRGB(236, 236, 250),
}
local LAVENDER = Color3.fromRGB(132, 96, 214)

local function flowerPatch(parent: Instance, rng: Random, pos: Vector3)
	local m = Instance.new("Model")
	m.Name = "Flores"
	local color = FLOWER_COLORS[rng:NextInteger(1, #FLOWER_COLORS)]
	for _ = 1, rng:NextInteger(7, 13) do
		local x, z = pos.X + rng:NextNumber(-2.5, 2.5), pos.Z + rng:NextNumber(-2.5, 2.5)
		local y = groundAt(x, z)
		if y then
			local stemH = rng:NextNumber(0.5, 1.2)
			deco(m, V(0.14, stemH, 0.14), CFrame.new(x, y + stemH / 2, z), Color3.fromRGB(74, 132, 46))
			deco(
				m,
				V(0.5, 0.25, 0.5),
				CFrame.new(x, y + stemH, z) * CFrame.Angles(0, rng:NextNumber(0, 3), 0),
				vary(rng, color, 0.04)
			)
		end
	end
	m.Parent = parent
end

-- Lavanda: espigas violetas de bloquecitos apilados.
local function lavender(parent: Instance, rng: Random, pos: Vector3)
	local m = Instance.new("Model")
	m.Name = "Lavanda"
	for _ = 1, rng:NextInteger(6, 12) do
		local x, z = pos.X + rng:NextNumber(-2, 2), pos.Z + rng:NextNumber(-2, 2)
		local y = groundAt(x, z)
		if y then
			local stemH = rng:NextNumber(1, 1.8)
			deco(m, V(0.12, stemH, 0.12), CFrame.new(x, y + stemH / 2, z), Color3.fromRGB(80, 124, 60))
			for i = 0, rng:NextInteger(2, 4) do
				local s = 0.4 - i * 0.05
				deco(m, V(s, 0.3, s), CFrame.new(x, y + stemH + i * 0.28, z), vary(rng, LAVENDER, 0.05))
			end
		end
	end
	m.Parent = parent
end

------------------------------------------------------------------------------------------------
-- Enredaderas

-- Una enredadera: tallo fino con hojas cuadradas a lo largo.
local function vine(parent: Instance, rng: Random, top: Vector3, len: number, out: Vector3?)
	local color = vary(rng, VINE, 0.06)
	deco(parent, V(0.2, len, 0.2), CFrame.new(top - V(0, len / 2, 0)), color)
	local n = math.floor(len / 0.9)
	for i = 1, n do
		local s = rng:NextNumber(0.6, 1.1)
		local side = V(rng:NextNumber(-0.25, 0.25), 0, rng:NextNumber(-0.25, 0.25)) + (out or Vector3.zero) * 0.15
		deco(
			parent,
			V(s, s, 0.12),
			CFrame.new(top - V(0, i * 0.9, 0) + side) * CFrame.Angles(0, rng:NextNumber(0, 3), 0),
			vary(rng, VINE, 0.08)
		)
	end
end

-- Cortinas de enredaderas colgando de los dos bordes del barranco, pegadas a la pared.
local function ravineVines(parent: Instance, rng: Random)
	local m = Instance.new("Model")
	m.Name = "EnredaderasBarranco"
	for x = -HALF + 4, HALF - 4, 1.1 do
		for _, side in { -1, 1 } do
			local topY = groundAt(x, ravineZ(x) + side * 13.5)
			if topY and rng:NextNumber() < 0.7 then
				local depth = topY - WATER_Y
				local z = ravineZ(x) + side * 10.8
				if rng:NextNumber() < 0.35 then
					-- hiedra: una lámina verde ancha que se lee de lejos
					local len = rng:NextNumber(0.3, 0.75) * depth
					deco(
						m,
						V(rng:NextNumber(1.6, 3.2), len, 0.3),
						CFrame.new(x, topY - len / 2 + 0.3, z + side * 0.3),
						vary(rng, Color3.fromRGB(62, 120, 44), 0.06)
					)
				else
					vine(m, rng, V(x, topY + 0.2, z), rng:NextNumber(0.25, 0.85) * depth, V(0, 0, -side))
				end
			end
		end
		if x % 12 < 1.1 then
			task.wait()
		end
	end
	m.Parent = parent
end
------------------------------------------------------------------------------------------------
-- Ruinas

local function pillar(parent: Instance, rng: Random, base: Vector3, blocks: number, mossy: boolean)
	local m = Instance.new("Model")
	m.Name = "Pilar"
	local y = base.Y
	local top = base
	for i = 1, blocks do
		local w = 3 - i * 0.1
		local h = rng:NextNumber(2.2, 3)
		local cf = CFrame.new(base.X + rng:NextNumber(-0.25, 0.25), y + h / 2, base.Z + rng:NextNumber(-0.25, 0.25))
			* CFrame.Angles(0, rng:NextNumber(-0.15, 0.15), rng:NextNumber(-0.04, 0.04))
		block(m, V(w, h, w), cf, vary(rng, STONE, 0.05))
		y += h
		top = V(cf.X, y, cf.Z)
	end
	if mossy then
		deco(m, V(2.7, 0.3, 2.7), CFrame.new(top + V(0, 0.15, 0)), vary(rng, MOSS, 0.05))
		for _ = 1, rng:NextInteger(1, 3) do
			local out = if rng:NextNumber() < 0.5 then V(0, 0, -1) else V(0, 0, 1)
			vine(m, rng, top + V(rng:NextNumber(-1, 1), 0, out.Z * 1.5), (y - base.Y) * rng:NextNumber(0.3, 0.7), out)
		end
	end
	m.Parent = parent
	return top
end

local function bridgeEnds(): (number, number)
	local c = ravineZ(BRIDGE_X)
	return c - 17, c + 17
end

local function ruins(parent: Instance, rng: Random)
	-- Anillo de pilares alrededor del claro, algunos rotos y caídos.
	for i = 0, 9 do
		local a = i / 10 * math.pi * 2 + 0.3
		local x, z = math.cos(a) * 24, math.sin(a) * 24
		local y = groundAt(x, z)
		if y then
			local broken = rng:NextNumber() < 0.45
			pillar(
				parent,
				rng,
				V(x, y - 0.3, z),
				if broken then rng:NextInteger(1, 2) else rng:NextInteger(3, 5),
				rng:NextNumber() < 0.75
			)
			if broken then
				local fx, fz = x + rng:NextNumber(-4, 4), z + rng:NextNumber(-4, 4)
				local fy = groundAt(fx, fz)
				if fy then
					block(
						parent,
						V(3, 2.6, 3),
						CFrame.new(fx, fy + 0.9, fz)
							* CFrame.Angles(rng:NextNumber(-0.5, 0.5), rng:NextNumber(0, 3), 1.2),
						vary(rng, STONE, 0.05)
					)
				end
			end
		end
	end

	-- Arco en la otra orilla, del otro lado del puente.
	local _, z1 = bridgeEnds()
	local ax, az = BRIDGE_X, z1 + 12
	local ay = groundAt(ax, az) or 16
	local tl = pillar(parent, rng, V(ax - 5, ay - 0.3, az), 4, true)
	local tr = pillar(parent, rng, V(ax + 5, ay - 0.3, az), 4, true)
	local topY = math.max(tl.Y, tr.Y)
	local lintel = block(parent, V(14, 2.4, 3), CFrame.new(ax, topY + 1.2, az), vary(rng, STONE, 0.04))
	deco(parent, V(13, 0.3, 2.8), lintel.CFrame * CFrame.new(0, 1.35, 0), vary(rng, MOSS, 0.05))
	for _ = 1, 6 do
		vine(parent, rng, V(ax + rng:NextNumber(-6, 6), topY, az - 1.6), rng:NextNumber(2, 5), V(0, 0, -1))
	end

	-- Muro roto al oeste.
	for i = 0, 6 do
		local x, z = -34 + rng:NextNumber(-0.3, 0.3), -14 + i * 3.1
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

	-- Camino de losas: del centro al puente, y del puente al arco.
	local z0, z1b = bridgeEnds()
	for _, seg in { { 6, z0 + 1 }, { z1b - 1, az - 2 } } do
		for z = seg[1], seg[2], 2.6 do
			local x = BRIDGE_X + math.sin(z / 9) * 2.5 + rng:NextNumber(-0.8, 0.8)
			local y = groundAt(x, z)
			if y then
				block(
					parent,
					V(rng:NextNumber(2.2, 3.2), 0.5, rng:NextNumber(2.2, 3.2)),
					CFrame.new(x, y + 0.05, z) * CFrame.Angles(0, rng:NextNumber(0, 1.5), 0),
					vary(rng, STONE, 0.06)
				)
			end
		end
	end

	-- Postes de madera viejos cerca del borde.
	for i = 0, 4 do
		local x = BRIDGE_X - 18 + i * 4.5
		local z = z0 - 4 + rng:NextNumber(-0.5, 0.5)
		local y = groundAt(x, z)
		if y then
			local h = rng:NextNumber(2.5, 4)
			block(
				parent,
				V(0.7, h, 0.7),
				CFrame.new(x, y + h / 2 - 0.3, z) * CFrame.Angles(0, 0, rng:NextNumber(-0.12, 0.12)),
				Color3.fromRGB(110, 72, 50)
			)
		end
	end
end

local function bridge(parent: Instance, rng: Random)
	local z0, z1 = bridgeEnds()
	local y0 = groundAt(BRIDGE_X, z0) or 10
	local y1 = groundAt(BRIDGE_X, z1) or 16
	local m = Instance.new("Model")
	m.Name = "Puente"
	local n = math.ceil((z1 - z0) / 3.2)
	for i = 0, n do
		local t = i / n
		local z = z0 + (z1 - z0) * t
		local y = y0 + (y1 - y0) * t + math.sin(t * math.pi) * 1.5 + 0.4 -- leve arco
		if rng:NextNumber() > 0.06 then
			block(
				m,
				V(6, 1.6, 3.1),
				CFrame.new(BRIDGE_X, y + rng:NextNumber(-0.15, 0.15), z)
					* CFrame.Angles(0, rng:NextNumber(-0.05, 0.05), 0),
				vary(rng, STONE, 0.05)
			)
			if rng:NextNumber() < 0.55 then
				local sx = if rng:NextNumber() < 0.5 then -3.1 else 3.1
				vine(m, rng, V(BRIDGE_X + sx, y - 0.8, z), rng:NextNumber(2, 7), V(sx / 3.1, 0, 0))
			end
			if i % 2 == 0 then
				for _, sx in { -2.6, 2.6 } do
					if rng:NextNumber() < 0.75 then
						block(m, V(0.9, 1.4, 0.9), CFrame.new(BRIDGE_X + sx, y + 1.5, z), vary(rng, STONE, 0.05))
					end
				end
			end
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
	while placed < n and tries < n * 25 do
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

local function nearRavine(x: number, z: number, margin: number): boolean
	return math.abs(z - ravineZ(x)) < 14 + margin
end

local function onPath(x: number, z: number): boolean
	return math.abs(x - BRIDGE_X) < 6 and z > 0
end

function ArenaBuilder.props()
	local rng = Random.new(SEED)
	local root = arenaFolder()

	local trees = getFolder(root, "Pinos")
	scatter(rng, 165, function(x, z, _y, mat)
		local r = math.sqrt(x * x + z * z)
		return r > 36 and isGrass(mat) and not nearRavine(x, z, 3) and not onPath(x, z)
	end, function(p)
		pine(trees, rng, p, rng:NextNumber(0.9, 1.7))
	end)

	local dead = getFolder(root, "ArbolesSecos")
	for _, p in { V(30, 0, 30), V(-40, 0, 72), V(46, 0, -20) } do
		local y = groundAt(p.X, p.Z)
		if y then
			deadTree(dead, rng, V(p.X, y, p.Z))
		end
	end

	local stones = getFolder(root, "Piedras")
	scatter(rng, 55, function(x, z)
		return math.sqrt(x * x + z * z) > 14 and not onPath(x, z)
	end, function(p)
		stoneBlock(stones, rng, p, rng:NextNumber(1.6, 4))
	end)

	local bushes = getFolder(root, "Arbustos")
	scatter(rng, 130, function(x, z, _y, mat)
		return isGrass(mat) and not onPath(x, z)
	end, function(p)
		bush(bushes, rng, p)
	end)

	local flowers = getFolder(root, "Flores")
	scatter(rng, 90, function(x, z, _y, mat)
		return isGrass(mat) and math.sqrt(x * x + z * z) < 90 and not onPath(x, z)
	end, function(p)
		flowerPatch(flowers, rng, p)
	end)
	scatter(rng, 55, function(x, z, _y, mat)
		return isGrass(mat) and math.sqrt(x * x + z * z) < 90 and not onPath(x, z)
	end, function(p)
		lavender(flowers, rng, p)
	end)

	local ruinsFolder = getFolder(root, "Ruinas")
	ruins(ruinsFolder, rng)
	bridge(ruinsFolder, rng)
	ravineVines(ruinsFolder, rng)
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
	-- Especie 1: adulto que pasea, cría a su lado y huevo.
	local musgo = {
		{ Species.Musgo, V(-6, 0, -22), 160, 1, true },
		{ Species.Musgo, V(2, 0, -24), 200, 0, true },
		{ Species.HuevoMusgo, V(-1, 0, -30), 0, 1, false },
	}
	for _, s in musgo do
		local def, pos, yaw, age, wander = s[1], s[2], s[3], s[4], s[5]
		local y = groundAt(pos.X, pos.Z) or 10
		local cf = CFrame.new(pos.X, y, pos.Z) * CFrame.Angles(0, math.rad(yaw), 0)
		local model = CreatureBuilder.build(def, cf, { age = age })
		model:SetAttribute("Wander", wander)
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
