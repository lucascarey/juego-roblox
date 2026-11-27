--!strict
-- IA de criaturas NPC (servidor). Cada criatura con el atributo IA = true tiene un "cerebro":
--   - Necesidades: hambre y energía (bajan con el tiempo y más rápido corriendo).
--   - Decide por utilidad: puntúa cada conducta según necesidades, grupo y amenazas, y se queda
--     con la mejor (con un poco de inercia para no cambiar de idea a cada rato).
--   - Grupos (atributo Grupo): familia o manada con un líder (Rol Madre/Lider). Las crías siguen de
--     cerca a la madre, los demás a distancia; si el líder descansa o duerme, el grupo lo imita.
--   - Amenazas: jugadores cerca, o quien la atacó. Crías y jóvenes huyen hacia la madre; la madre
--     defiende a sus crías con coletazo o cabezazo; un adulto solo y herido huye.
--   - Movimiento: giro limitado, frena en curvas, se separa de los compañeros, esquiva el cerco y
--     sigue el terreno. Solo mueve la Root (anclada); las patas las anima cada cliente.
-- Rendimiento: decide unas pocas veces por segundo (cada vez menos si no hay jugadores cerca)
-- y el movimiento es una suma de vectores por criatura: cientos de criaturas no pesan.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local SpeciesStats = require(ReplicatedStorage.Shared.Creatures.SpeciesStats)
local CreatureCombat = require(script.Parent.CreatureCombat)

local THINK_NEAR = 0.4 -- segundos entre decisiones con jugadores cerca
local THINK_FAR = 2
local NEAR_DIST = 200
local SLEEP_DIST = 400 -- más lejos: ni se mueve (nadie la ve)

type Group = { id: string, members: { Brain }, leader: Brain? }
export type Brain = {
	model: Model,
	root: BasePart,
	stats: SpeciesStats.Stats,
	age: number,
	scale: number,
	bodyLen: number,
	role: string,
	group: Group?,
	home: Vector3,
	hover: number,
	rng: Random,
	hunger: number, -- 1 = lleno
	energy: number, -- 1 = descansado
	behavior: string,
	since: number, -- cuándo empezó la conducta actual
	until_: number, -- conductas con duración (comer, excavar)
	target: Vector3?,
	speed: number, -- velocidad deseada
	cur: number, -- velocidad actual
	nextThink: number,
	threat: Model?,
	nextAttack: number,
	lockedUntil: number, -- levantándose
	lastPlayerDist: number,
}

local brains: { [Model]: Brain } = {}
local groups: { [string]: Group } = {}

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Include
groundParams.FilterDescendantsInstances = { workspace.Terrain }
local obstacleParams = RaycastParams.new()
obstacleParams.FilterType = Enum.RaycastFilterType.Exclude

local function groundAt(p: Vector3): number?
	local hit = workspace:Raycast(p + Vector3.new(0, 60, 0), Vector3.new(0, -200, 0), groundParams)
	return if hit then hit.Position.Y else nil
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

-- ------------------------------------------------------------------------------------------
-- Alta y baja

local function refreshObstacleFilter()
	local list = {}
	for m in brains do
		table.insert(list, m)
	end
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(list, p.Character)
		end
	end
	obstacleParams.FilterDescendantsInstances = list
end

local function track(inst: Instance)
	if not inst:IsA("Model") or not inst:GetAttribute("IA") or brains[inst] then
		return
	end
	local model = inst :: Model
	local root = model.PrimaryPart
	local stats = SpeciesStats.get(model:GetAttribute("Species") :: string? or "")
	if not root or not stats then
		return
	end
	local age = model:GetAttribute("Age") :: number? or 1
	local rear = model:FindFirstChild("Rear") :: BasePart?
	local chest = model:FindFirstChild("Chest") :: BasePart?
	local rng = Random.new()
	local b: Brain = {
		model = model,
		root = root,
		stats = stats,
		age = age,
		scale = SpeciesStats.ageScale(age),
		bodyLen = (if rear then rear.Size.Z else 2) + (if chest then chest.Size.Z else 2),
		role = model:GetAttribute("Rol") :: string? or "Solo",
		group = nil,
		home = root.Position,
		hover = root.Position.Y - (groundAt(root.Position) or root.Position.Y),
		rng = rng,
		hunger = rng:NextNumber(0.5, 1),
		energy = rng:NextNumber(0.5, 1),
		behavior = "Explorar",
		since = os.clock(),
		until_ = 0,
		target = nil,
		speed = 0,
		cur = 0,
		nextThink = os.clock() + rng:NextNumber(0, THINK_NEAR), -- repartidas en el tiempo
		threat = nil,
		nextAttack = 0,
		lockedUntil = 0,
		lastPlayerDist = math.huge,
	}
	local gid = model:GetAttribute("Grupo") :: string?
	if gid then
		local g = groups[gid] or { id = gid, members = {}, leader = nil }
		groups[gid] = g
		table.insert(g.members, b)
		if b.role == "Madre" or b.role == "Lider" then
			g.leader = b
		end
		b.group = g
	end
	brains[model] = b
	refreshObstacleFilter()
end

local function untrack(inst: Instance)
	local b = brains[inst :: Model]
	if not b then
		return
	end
	brains[inst :: Model] = nil
	local g = b.group
	if g then
		local i = table.find(g.members, b)
		if i then
			table.remove(g.members, i)
		end
		if g.leader == b then
			g.leader = nil
		end
	end
	refreshObstacleFilter()
end

CollectionService:GetInstanceAddedSignal("Creature"):Connect(track)
CollectionService:GetInstanceRemovedSignal("Creature"):Connect(untrack)
for _, m in CollectionService:GetTagged("Creature") do
	track(m)
end
Players.PlayerAdded:Connect(function(p)
	p.CharacterAdded:Connect(refreshObstacleFilter)
end)

-- ------------------------------------------------------------------------------------------
-- Percepción

-- Jugador (humano o criatura) más cercano y si alguien la atacó hace poco.
local function perceive(b: Brain): (Model?, number)
	local pos = b.root.Position
	local best, bestD = nil, math.huge
	for _, p in Players:GetPlayers() do
		local ch = p.Character
		local r = ch and ch.PrimaryPart
		local hum = ch and ch:FindFirstChildOfClass("Humanoid")
		if ch and r and hum and hum.Health > 0 then
			local d = (r.Position - pos).Magnitude
			if d < bestD then
				best, bestD = ch, d
			end
		end
	end
	b.lastPlayerDist = bestD
	local by = b.model:GetAttribute("AtacadoPor") :: string?
	local at = b.model:GetAttribute("AtacadoEn") :: number?
	if by and at and os.clock() - at < 12 then
		local attacker = Players:FindFirstChild(by) :: Player?
		if attacker and attacker.Character then
			return attacker.Character, -1 -- -1 = me atacó (amenaza máxima)
		end
	end
	return best, bestD
end

-- ------------------------------------------------------------------------------------------
-- Decisión (utilidad)

local function setPosture(b: Brain, posture: string?)
	local current = b.model:GetAttribute("Postura")
	if current == posture then
		return
	end
	if current and not posture then
		b.lockedUntil = os.clock() + (if current == "Durmiendo" then b.stats.standUpSleep else b.stats.standUpRest)
	end
	b.model:SetAttribute("Postura", posture)
end

local function startBehavior(b: Brain, name: string)
	if b.behavior == name then
		return
	end
	b.behavior = name
	b.since = os.clock()
	b.target = nil
	b.model:SetAttribute("IA_Estado", name) -- para ver en Studio qué está haciendo
	if
		name ~= "Comer"
		and name ~= "Excavar"
		and not CreatureCombat.TIMING[b.model:GetAttribute("Accion") :: string? or ""]
	then
		b.model:SetAttribute("Accion", nil)
	end
	if name ~= "Descansar" and name ~= "Dormir" then
		setPosture(b, nil)
	end
end

local function isYoung(b: Brain): boolean
	return b.age < 0.75
end

local function think(b: Brain)
	local now = os.clock()
	local threat, td = perceive(b)
	local attacked = td == -1
	local perception = 30 * (0.6 + 0.4 * b.scale)
	local threatNear = attacked or (threat ~= nil and td < perception)
	local g = b.group
	local leader = g and g.leader
	local isLeader = leader == b or leader == nil

	-- Puntajes. La conducta actual suma un poco para no cambiar de idea por cualquier cosa.
	local score: { [string]: number } = {}
	score.Explorar = 0.25
	score.Comer = if b.hunger < 0.6 then (1 - b.hunger) * 0.9 else 0
	score.Excavar = if b.hunger < 0.85 then 0.12 else 0
	score.Descansar = if b.energy < 0.35 then (1 - b.energy) * 0.85 else 0
	score.Dormir = if b.energy < 0.15 then 1 else 0
	if not isLeader and leader then
		local d = flat(leader.root.Position - b.root.Position).Magnitude
		local keep = (if isYoung(b) then 6 else 12) * (0.5 + 0.5 * leader.scale)
		score.Seguir = math.clamp((d - keep) / keep, 0, 1) * 0.9
		-- Imitar al líder: si descansa o duerme, el grupo también.
		local lp = leader.model:GetAttribute("Postura")
		if lp == "Durmiendo" then
			score.Dormir = math.max(score.Dormir, 0.7)
		elseif lp == "Acostado" then
			score.Descansar = math.max(score.Descansar, 0.6)
		end
	end
	if threatNear and threat then
		local hum = b.model:FindFirstChildOfClass("Humanoid")
		local hurt = hum and hum.Health < hum.MaxHealth * 0.35
		local defendsYoung = false
		if b.role == "Madre" and g then
			for _, m in g.members do
				if m ~= b and isYoung(m) then
					local tp = (threat.PrimaryPart :: BasePart).Position
					if (m.root.Position - tp).Magnitude < 16 then
						defendsYoung = true
					end
				end
			end
		end
		if isYoung(b) then
			score.Huir = 1.2
		elseif (defendsYoung or attacked) and not hurt then
			score.Defender = 1.3
		elseif attacked or hurt then
			score.Huir = 1.1
		end
		-- Con una amenaza cerca nadie se queda dormido.
		score.Dormir, score.Descansar = 0, 0
	end
	b.threat = threat

	-- Conductas con duración: no se interrumpen salvo por algo urgente.
	local current = b.behavior
	if (current == "Comer" or current == "Excavar") and now < b.until_ and not threatNear then
		return
	end
	score[current] = (score[current] or 0) + 0.15

	local best, bestScore = "Explorar", -1
	for name, s in score do
		if s > bestScore then
			best, bestScore = name, s
		end
	end
	-- Dormir pasa por acostarse primero.
	if best == "Dormir" and b.model:GetAttribute("Postura") == nil then
		best = "Descansar"
	end
	startBehavior(b, best)

	-- Preparar la conducta elegida.
	local pos = b.root.Position
	local sp = SpeciesStats.speedScale(b.model:GetAttribute("Age") :: number? or 1)
	local walk, trot, sprint = b.stats.walk * sp, b.stats.walk * 1.4 * sp, b.stats.sprint * sp
	if best == "Explorar" then
		if not b.target or flat(b.target - pos).Magnitude < 2 then
			-- El líder/solitario explora alrededor de su casa; los demás alrededor del líder.
			local center = if not isLeader and leader then leader.root.Position else b.home
			local a = b.rng:NextNumber(0, 2 * math.pi)
			local r = b.rng:NextNumber(4, if isLeader then 24 else 8)
			b.target = center + Vector3.new(math.cos(a) * r, 0, math.sin(a) * r)
			b.speed = if b.rng:NextNumber() < 0.15 then trot else walk
		end
	elseif best == "Seguir" and leader then
		-- Detrás y al costado del líder, cada uno en su lugar.
		local lcf = leader.root.CFrame
		local i = if g then table.find(g.members, b) or 1 else 1
		local side = if i % 2 == 0 then 1 else -1
		b.target = lcf.Position + lcf.RightVector * side * 3 * leader.scale + lcf.LookVector * -4 * leader.scale
		local d = flat(b.target - pos).Magnitude
		b.speed = if d > 20 then sprint elseif d > 8 then trot else walk
	elseif best == "Comer" then
		if b.model:GetAttribute("Accion") ~= "Comer" then
			b.model:SetAttribute("Accion", "Comer")
			b.until_ = now + b.rng:NextNumber(5, 9)
		end
		b.speed = 0
	elseif best == "Excavar" then
		if b.model:GetAttribute("Accion") ~= "Excavar" then
			b.model:SetAttribute("Accion", "Excavar")
			b.until_ = now + 2.5
		end
		b.speed = 0
	elseif best == "Descansar" then
		setPosture(b, "Acostado")
		b.speed = 0
	elseif best == "Dormir" then
		setPosture(b, "Durmiendo")
		b.speed = 0
	elseif best == "Huir" and threat then
		local tp = (threat.PrimaryPart :: BasePart).Position
		local away = flat(pos - tp).Unit
		-- Las crías corren hacia la madre si la madre no está del lado de la amenaza.
		local dest = pos + away * 20
		if isYoung(b) and leader and leader ~= b then
			local lp = leader.root.Position
			if (lp - tp).Magnitude > (pos - tp).Magnitude * 0.6 then
				dest = lp + flat(lp - tp).Unit * 4
			end
		end
		b.target = dest
		b.speed = sprint
	elseif best == "Defender" and threat then
		local tp = (threat.PrimaryPart :: BasePart).Position
		local rel = b.root.CFrame:PointToObjectSpace(tp)
		local dist = flat(rel).Magnitude
		local tailReach = b.bodyLen * 0.5 + b.bodyLen * 1.3
		if now >= b.nextAttack and b.model:GetAttribute("Postura") == nil then
			if rel.Z < 0 and dist < b.bodyLen * 0.9 and math.abs(rel.X) < b.bodyLen * 0.5 then
				b.nextAttack = now + (CreatureCombat.attack(b.model, b.stats.frontAttack, "IA") or 1) + 0.6
			elseif rel.Z > -b.bodyLen * 0.2 and dist < tailReach then
				b.nextAttack = now + (CreatureCombat.attack(b.model, "Coletazo", "IA") or 1.5) + 0.8
			end
		end
		-- Se acerca de frente; si quedó cerca de costado, se queda (el coletazo la alcanza).
		b.target = if dist > b.bodyLen * 0.8 then tp else nil
		b.speed = trot
	end
end

-- ------------------------------------------------------------------------------------------
-- Necesidades

local function updateNeeds(b: Brain, dt: number)
	local posture = b.model:GetAttribute("Postura")
	local running = b.cur > b.stats.walk * 1.5 * SpeciesStats.speedScale(b.model:GetAttribute("Age") :: number? or 1)
	b.hunger = math.max(0, b.hunger - dt / (if running then 120 else 240))
	if b.behavior == "Comer" then
		b.hunger = math.min(1, b.hunger + dt / 8)
	elseif b.behavior == "Excavar" then
		b.hunger = math.min(1, b.hunger + dt / 20)
	end
	if posture == "Durmiendo" then
		b.energy = math.min(1, b.energy + dt / 25)
	elseif posture == "Acostado" then
		b.energy = math.min(1, b.energy + dt / 45)
	else
		b.energy = math.max(0, b.energy - dt / (if running then 90 else 300))
	end
	-- Ya descansada: se levanta sola (si no la retiene el grupo).
	if (b.behavior == "Descansar" or b.behavior == "Dormir") and b.energy > 0.95 then
		local leader = b.group and b.group.leader
		local leaderRests = leader and leader ~= b and leader.model:GetAttribute("Postura") ~= nil
		if not leaderRests then
			startBehavior(b, "Explorar")
		end
	end
end

-- ------------------------------------------------------------------------------------------
-- Movimiento

local TURN_RATE = 1.8 -- rad/s caminando; corriendo gira más abierto

-- Radio de las criaturas sin IA (huevos y las de los jugadores), medido una vez.
local radiusOf: { [Model]: number } = setmetatable({}, { __mode = "k" }) :: any

-- Separación por posición: si otra criatura, un huevo o la criatura de un jugador se metió en su lugar,
-- se corre de a poco hacia afuera. Sin física (las criaturas son ancladas): barato y sin temblores.
local function separate(b: Brain, pos: Vector3, dt: number): Vector3
	local push = Vector3.zero
	local r = b.bodyLen * 0.45
	for _, other in CollectionService:GetTagged("Creature") do
		if other == b.model or not other:IsA("Model") or not other.PrimaryPart then
			continue
		end
		local ob = brains[other]
		local ro = if ob then ob.bodyLen * 0.45 else radiusOf[other]
		if not ro then
			local size = other:GetExtentsSize()
			ro = math.max(size.X, size.Z) * (if other:GetAttribute("Jugador") then 0.3 else 0.5)
			radiusOf[other] = ro
		end
		local off = flat(pos - other.PrimaryPart.Position)
		local d = off.Magnitude
		local minD = r + ro
		if d > 0.01 and d < minD then
			push += off.Unit * (minD - d)
		end
	end
	return push * math.min(1, 6 * dt)
end

local function move(b: Brain, dt: number)
	local cf = b.root.CFrame
	local pos = cf.Position
	local target = b.target
	local locked = b.model:GetAttribute("Postura") ~= nil or os.clock() < b.lockedUntil
	local want = 0
	local dir = cf.LookVector
	if target and not locked then
		local to = flat(target - pos)
		local dist = to.Magnitude
		if dist > 1 then
			local steer = to.Unit
			-- Separación de compañeros y otras criaturas cercanas.
			for other, ob in brains do
				if other ~= b.model then
					local off = flat(pos - ob.root.Position)
					local minD = (b.bodyLen + ob.bodyLen) * 0.45
					local d = off.Magnitude
					if d > 0.01 and d < minD then
						steer += off.Unit * (minD - d) / minD * 1.5
					end
				end
			end
			-- Cerco u obstáculo adelante: girar hacia el lado libre.
			local ahead = cf.LookVector * (b.bodyLen + b.cur * 0.6)
			local hit = workspace:Raycast(pos + Vector3.new(0, 1 + b.hover, 0), ahead, obstacleParams)
			if hit and hit.Instance ~= workspace.Terrain then
				local n = flat(hit.Normal)
				if n.Magnitude > 0.1 then
					steer += n.Unit * 2
				end
			end
			if steer.Magnitude > 0.01 then
				dir = steer.Unit
			end
			want = b.speed * math.clamp(dist / 3, 0.3, 1)
		end
	end
	-- Girar hacia la dirección deseada con velocidad de giro limitada; frena en curvas cerradas.
	local look = cf.LookVector
	local have = math.atan2(-look.X, -look.Z)
	local wantYaw = math.atan2(-dir.X, -dir.Z)
	local diff = (wantYaw - have + math.pi) % (2 * math.pi) - math.pi
	local rate = TURN_RATE / (1 + b.cur / 12)
	local yaw = math.clamp(diff, -rate * dt, rate * dt)
	want *= math.clamp(1 - math.abs(diff) / 1.6, 0.15, 1)
	b.cur += math.clamp(want - b.cur, -8 * dt, 5 * dt)
	cf = cf * CFrame.Angles(0, yaw, 0)
	cf += cf.LookVector * b.cur * dt
	if b.model:GetAttribute("Postura") == nil then -- acostada o dormida no se desliza
		cf += separate(b, cf.Position, dt)
	end
	local gy = groundAt(cf.Position)
	if gy then
		local y = cf.Y + (gy + b.hover - cf.Y) * math.min(1, 10 * dt)
		cf = CFrame.new(cf.X, y, cf.Z) * cf.Rotation
	end
	b.root.CFrame = cf
end

-- ------------------------------------------------------------------------------------------
-- Bucle

RunService.Heartbeat:Connect(function(dt)
	local now = os.clock()
	for model, b in brains do
		if not model.Parent or not b.root.Parent then
			untrack(model)
			continue
		end
		local far = b.lastPlayerDist > NEAR_DIST
		if now >= b.nextThink then
			think(b)
			b.nextThink = now + (if far then THINK_FAR else THINK_NEAR) * b.rng:NextNumber(0.8, 1.2)
		end
		updateNeeds(b, dt)
		if b.lastPlayerDist < SLEEP_DIST then
			move(b, dt)
		end
	end
end)
