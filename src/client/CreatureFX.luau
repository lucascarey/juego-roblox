--!strict
-- Sonidos y partículas de las criaturas, en este cliente. El animador avisa los momentos
-- (pisada, caída, rascada, golpe, etc.) y acá se reproducen en 3D, adaptados al tamaño de la
-- criatura y al material del suelo. Para cambiar un sonido, cambiar su id en SOUNDS.
-- Audio: grafo nuevo de Roblox (AudioPlayer -> AudioEmitter). El oyente lo crea Roblox en la cámara
-- (SoundService.DefaultListenerLocation = Camera, que ya viene así); no hace falta configurarlo.

local Debris = game:GetService("Debris")

local CreatureFX = {}

-- Sonidos gratis de la Creator Store (ProSoundEffects, salvo las pisadas). Varias variantes = al azar.
local SOUNDS = {
	paso = { 129956418693357, 78534941650081, 110522236020035, 135037154891351 },
	latigo = { 9120710054, 9120713942 },
	golpe = { 9116488438, 9116489824 },
	excavar = { 9114083746, 9114083260 },
	caida = { 9125965076 },
	resoplido = { 9113629973, 9113630351 },
	respira = { 9120038269 },
}

local TEX_BLOQUE = "rbxassetid://104645684522940"
local TEX_POLVO = "rbxassetid://140493408826019"
local MAX_DIST = 140 -- más lejos no se escucha ni se ve: no se genera

local rng = Random.new()

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Include
groundParams.FilterDescendantsInstances = { workspace.Terrain }

-- Colores según el suelo: pasto, tierra y polvo.
local function palette(material: Enum.Material?): (Color3, Color3, Color3)
	if material == Enum.Material.Sand then
		return Color3.fromRGB(214, 196, 140), Color3.fromRGB(190, 168, 110), Color3.fromRGB(226, 212, 170)
	elseif material == Enum.Material.Rock or material == Enum.Material.Slate then
		return Color3.fromRGB(130, 130, 130), Color3.fromRGB(110, 110, 112), Color3.fromRGB(170, 170, 170)
	end
	return Color3.fromRGB(104, 150, 46), Color3.fromRGB(112, 82, 54), Color3.fromRGB(176, 160, 122)
end

local function groundAt(pos: Vector3): (Vector3, Enum.Material?)
	local hit = workspace:Raycast(pos + Vector3.new(0, 3, 0), Vector3.new(0, -12, 0), groundParams)
	if hit then
		return hit.Position, hit.Material
	end
	return pos, nil
end

local function near(pos: Vector3): boolean
	local cam = workspace.CurrentCamera
	return cam ~= nil and (cam.CFrame.Position - pos).Magnitude < MAX_DIST
end

-- Sonido 3D de una sola vez en una posición.
local function sound(kind: string, pos: Vector3, volume: number, pitch: number)
	local list = SOUNDS[kind]
	if not list then
		return
	end
	local att = Instance.new("Attachment")
	att.WorldPosition = pos
	att.Parent = workspace.Terrain
	local player = Instance.new("AudioPlayer")
	player.AssetId = "rbxassetid://" .. list[rng:NextInteger(1, #list)]
	player.Volume = volume
	player.PlaybackSpeed = pitch * rng:NextNumber(0.93, 1.07)
	player.Parent = att
	local emitter = Instance.new("AudioEmitter")
	emitter.Parent = att
	-- Volumen según la distancia (studs -> 0..1).
	emitter:SetDistanceAttenuation({ [0] = 1, [25] = 0.45, [70] = 0.12, [MAX_DIST] = 0 })
	local wire = Instance.new("Wire")
	wire.SourceInstance = player
	wire.TargetInstance = emitter
	wire.Parent = att
	player:Play()
	Debris:AddItem(att, 4)
end

type Burst = {
	texture: string,
	color: Color3,
	count: number,
	size: number,
	speed: NumberRange,
	spread: number,
	life: NumberRange,
	gravity: number,
	direction: Vector3?,
	fade: boolean?,
}

-- Ráfaga de partículas pixeladas.
local function burst(pos: Vector3, b: Burst)
	local att = Instance.new("Attachment")
	local dir = b.direction or Vector3.yAxis
	att.WorldCFrame = CFrame.lookAt(pos, pos + dir) -- EmissionDirection Front = hacia dir
	att.Parent = workspace.Terrain
	local e = Instance.new("ParticleEmitter")
	e.Texture = b.texture
	e.Color = ColorSequence.new(b.color)
	e.LightEmission = 0
	e.LightInfluence = 1
	e.Enabled = false
	e.EmissionDirection = Enum.NormalId.Front
	e.SpreadAngle = Vector2.new(b.spread, b.spread)
	e.Speed = b.speed
	e.Lifetime = b.life
	e.Acceleration = Vector3.new(0, -b.gravity, 0)
	e.Drag = if b.fade then 3 else 1
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = NumberRange.new(-120, 120)
	e.Size = if b.fade
		then NumberSequence.new({
			NumberSequenceKeypoint.new(0, b.size * 0.6),
			NumberSequenceKeypoint.new(1, b.size * 1.6),
		})
		else NumberSequence.new(b.size)
	e.Transparency = if b.fade
		then NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.35),
			NumberSequenceKeypoint.new(1, 1),
		})
		else NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.8, 0),
			NumberSequenceKeypoint.new(1, 1),
		})
	e.Parent = att
	e:Emit(b.count)
	Debris:AddItem(att, b.life.Max + 0.2)
end

local function dust(pos: Vector3, color: Color3, s: number, count: number, spread: number?)
	burst(pos, {
		texture = TEX_POLVO,
		color = color,
		count = count,
		size = 1.6 * s,
		speed = NumberRange.new(2 * s, 5 * s),
		spread = spread or 70,
		life = NumberRange.new(0.5, 0.9),
		gravity = -1, -- el polvo sube apenas
		fade = true,
	})
end

local function chunks(pos: Vector3, color: Color3, s: number, count: number, dir: Vector3?, spread: number?)
	burst(pos, {
		texture = TEX_BLOQUE,
		color = color,
		count = count,
		size = 0.65 * s,
		speed = NumberRange.new(6 * s, 11 * s),
		spread = spread or 35,
		life = NumberRange.new(0.7, 1.1),
		gravity = 45,
		direction = dir,
	})
end

export type Event = {
	pos: Vector3,
	size: number, -- largo de pata de la criatura (adulta ~3.4): escala volumen, tono y partículas
	speed: number?,
	dir: Vector3?,
}

function CreatureFX.play(name: string, ev: Event)
	if not near(ev.pos) then
		return
	end
	local s = math.clamp(ev.size / 3.4, 0.3, 1.6) -- 1 = adulta
	local pitch = 1.25 - 0.4 * s -- las crías suenan más agudo
	local ground, material = groundAt(ev.pos)
	local grass, dirt, dustColor = palette(material)
	if name == "Pisada" then
		-- 0 caminando, 1 galopando: el polvo solo sale corriendo.
		local fast = math.clamp(((ev.speed or 0) / ev.size - 2.5) / 2, 0, 1)
		sound("paso", ground, (0.25 + 0.25 * fast) * (0.5 + 0.5 * s), pitch * 0.8)
		if fast > 0.3 then
			dust(ground, dustColor, s * 0.6, 2)
		end
	elseif name == "Caida" then
		sound("caida", ground, 0.8 * s, pitch)
		dust(ground, dustColor, s, 12, 85)
		chunks(ground, dirt, s, 5, nil, 60)
	elseif name == "Salto" then
		sound("resoplido", ev.pos, 0.35 * s, pitch)
		dust(ground, dustColor, s, 6, 80)
	elseif name == "Rascada" then
		sound("excavar", ground, 0.5 * s, pitch)
		-- Tierra y terrones que salen despedidos hacia atrás y arriba.
		local back = (ev.dir or Vector3.zAxis) + Vector3.new(0, 1.2, 0)
		chunks(ground, dirt, s, 10, back.Unit, 30)
		chunks(ground, grass, s, 2, back.Unit, 30)
		dust(ground, dustColor, s * 0.7, 2)
	elseif name == "Latigazo" or name == "Embestida" then
		sound("latigo", ev.pos, 0.45 * s, if name == "Latigazo" then pitch * 0.75 else pitch)
	elseif name == "ColaGolpe" then
		sound("golpe", ground, 0.35 * s, pitch * 0.8)
		chunks(ground, grass, s, 10, ev.dir and (ev.dir + Vector3.new(0, 1, 0)).Unit, 40)
		dust(ground, dustColor, s, 4)
	elseif name == "CabezaGolpe" then
		sound("golpe", ev.pos, 0.55 * s, pitch)
		dust(ev.pos, dustColor, s * 0.6, 3)
	elseif name == "Frenada" then
		sound("excavar", ground, 0.4 * s, pitch * 1.2)
		dust(ground, dustColor, s, 10, 50)
		chunks(ground, dirt, s, 5, ev.dir and (ev.dir + Vector3.new(0, 0.6, 0)).Unit, 30)
	elseif name == "Resoplido" then
		sound("resoplido", ev.pos, 0.3 * s, pitch)
	elseif name == "RespiraDormida" then
		sound("respira", ev.pos, 0.12 * s, pitch * 0.6)
	end
end

return CreatureFX
