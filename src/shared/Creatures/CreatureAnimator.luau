--!strict
-- Animación procedural de criaturas de cajas (corre en el cliente: Motor6D.Transform no se replica).
-- Lee el movimiento de la Root (que mueve el servidor) y de ahí saca todo:
--   - Paso: caminata en secuencia lateral que pasa a trote (pares diagonales) con la velocidad.
--     La zancada se calcula con el largo real de la pata, así las patas de apoyo no patinan.
--   - Cuerpo: baja cuando las patas de apoyo se inclinan, rola y flexiona la columna al girar.
--   - Cuello y cabeza: compensan el cabeceo del cuerpo, adelantan los giros y miran alrededor en reposo.
--   - Cola, antenas y barba: resortes con inercia (se quedan atrás y rebotan cuando el cuerpo acelera).
--   - Terreno: rayos bajo cada cadera; el cuerpo se inclina con la pendiente y cada pata dobla la
--     rodilla (IK de dos huesos) para apoyar en el suelo real, manteniéndose vertical.
--   - Reposo: respiración y cambio de peso.
--   - Acciones (atributos "Accion"/"AccionId" que pone el servidor): "Comer", "Excavar",
--     "Coletazo" y "Cabezazo".
--   - Postura (atributo "Postura"): "Acostado" y "Durmiendo" (cabeza al suelo). Se acuesta de adelante
--     hacia atrás y se levanta al revés, sin saltos; dormido tarda más en levantarse.
--   - En el aire (salto o caída) recoge las patas y al caer amortigua.
--   - Eventos para sonido y partículas (onEvent): Pisada, Caida, Salto, Rascada, Latigazo, ColaGolpe,
--     Embestida, CabezaGolpe, Frenada, Resoplido, RespiraDormida.
-- Funciona con cualquier especie que use los nombres de piezas de tools/creatures.py.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local CreatureAnimator = {}
CreatureAnimator.__index = CreatureAnimator

-- En el cliente: el jugador local mueve la cabeza de su criatura con la cámara.
local LOCAL_ID = if RunService:IsClient() and Players.LocalPlayer then Players.LocalPlayer.UserId else nil

local TAU = 2 * math.pi
-- Pose de reposo de los pétalos en el modelo (tools/creatures.py, tilt): el animador la descuenta.
local PETAL_REST = math.rad(43)
local TIP_REST = math.rad(30)

type Spring = { x: number, v: number }
type Chain = {
	motors: { Motor6D },
	kind: string, -- "up" (antenas), "down" (barba), "back" (cola)
	base: BasePart,
	a: { Spring }, -- eje X (cabeceo)
	b: { Spring }, -- eje Z (up/down) o Y (back)
	r: { number }, -- distancia de cada pieza a la base, para convertir desplazamiento en ángulo
	freq: { number },
	damp: number,
	prev: CFrame,
	fr: Vector3?, -- entrada filtrada (giro)
	fd: Vector3?, -- entrada filtrada (desplazamiento)
	fix: { number }?, -- cola acostada: corrección por bloque hasta tocar el suelo
}
type Leg = {
	upper: Motor6D,
	lower: Motor6D?,
	front: boolean,
	left: boolean,
	hip: Vector3, -- cadera en el espacio de la Root, en reposo
	a: number, -- cadera a rodilla
	b: number, -- rodilla al tobillo
	D0: number, -- cadera al tobillo en reposo (= a + b si la pata está recta; menos si está doblada)
	shorten: Spring, -- cuánto tiene que acortarse para apoyar en el suelo real
	swing: number, -- ángulo de paso del último cuadro (para buscar el suelo donde está el pie)
	plant: Vector3?, -- quieta: dónde quedó apoyado el pie (en el mundo)
	wasStance: boolean,
	lastStep: number,
	foot: Motor6D?, -- pie aparte (se mantiene plano)
	flex: number, -- 1 rodilla adelante; -1 rodilla atrás (pata de ave): flexionar gira al revés
	plantW: Spring,
}

-- Los rayos al suelo ignoran a todas las criaturas.
local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
local ignored: { Instance } = {}

local function newSpring(): Spring
	return { x = 0, v = 0 }
end

-- Resorte amortiguado (Euler semi-implícito), definido por frecuencia (Hz) y amortiguación (1 = crítico).
local function step(s: Spring, target: number, freq: number, damp: number, dt: number)
	local w = TAU * freq
	-- Subpasos para que sea estable aunque el cuadro sea lento (Euler diverge con w*dt > ~2).
	local n = math.ceil(w * dt / 0.5)
	local h = dt / n
	for _ = 1, n do
		s.v += (w * w * (target - s.x) - 2 * damp * w * s.v) * h
		s.x += s.v * h
	end
end

local function smooth(k: number): number
	return k * k * (3 - 2 * k)
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local function motorsByName(model: Model): { [string]: Motor6D }
	local out = {}
	for _, d in model:GetDescendants() do
		if d:IsA("Motor6D") then
			out[d.Name] = d
		end
	end
	return out
end

local function newChain(motors: { Motor6D }, kind: string, freqs: { number }, damp: number): Chain?
	if #motors == 0 then
		return nil
	end
	local base = motors[1].Part0 :: BasePart
	local r, dist = {}, 0
	for i, m in motors do
		local len = (m.Part1 :: BasePart).Size.Magnitude * 0.5
		r[i] = dist + len * 0.5
		dist += len
	end
	local a, b, freq = {}, {}, {}
	for i in motors do
		a[i], b[i] = newSpring(), newSpring()
		freq[i] = freqs[math.min(i, #freqs)]
	end
	return {
		motors = motors,
		kind = kind,
		base = base,
		a = a,
		b = b,
		r = r,
		freq = freq,
		damp = damp,
		prev = base.CFrame,
	}
end

function CreatureAnimator.new(model: Model)
	local root = model.PrimaryPart :: BasePart
	local m = motorsByName(model)
	local self = setmetatable({}, CreatureAnimator)
	self.model = model
	self.root = root
	self.m = m
	self.isEgg = m.Capa1 ~= nil

	-- Pieza raíz del cuerpo (la que cuelga de la Root) y columna.
	for _, motor in m do
		if motor.Part0 == root then
			self.body = motor
		end
	end
	self.spine = if m.Chest and m.Chest ~= self.body then m.Chest else nil
	-- Bípeda: tiene patas traseras pero no delanteras (camina, corre y excava distinto).
	self.biped = m.LegBUL ~= nil and m.LegFUL == nil

	-- Pose de reposo armada desde las articulaciones (las posiciones vivas pueden no estar resueltas
	-- todavía cuando la criatura recién llega por streaming).
	local rest: { [BasePart]: CFrame } = { [root] = CFrame.identity }
	local pending = {}
	for _, motor in m do
		table.insert(pending, motor)
	end
	while #pending > 0 do
		local progressed = false
		for i = #pending, 1, -1 do
			local motor = pending[i]
			local p0 = rest[motor.Part0 :: BasePart]
			if p0 then
				rest[motor.Part1 :: BasePart] = p0 * motor.C0 * motor.C1:Inverse()
				table.remove(pending, i)
				progressed = true
			end
		end
		if not progressed then
			break
		end
	end
	-- Piso en reposo: el punto más bajo de las patas (pies, dedos) si las tiene; si no, de toda la criatura.
	-- (Una boca o cabeza grande de cría puede quedar más abajo que los pies y no es el apoyo.)
	local hasLegs = m.LegBUL ~= nil or m.LegFUL ~= nil
	local function isLeg(name: string): boolean
		return name:match("^Leg") ~= nil
			or name:match("^Foot") ~= nil
			or name:match("^Toe") ~= nil
			or name:match("^Claw") ~= nil
			or name:match("^Paw") ~= nil
	end
	local lowest = math.huge
	for part, cf in rest do
		if part ~= root and (not hasLegs or isLeg(part.Name)) then
			local half = part.Size / 2
			for _, sx in { -1, 1 } do
				for _, sy in { -1, 1 } do
					for _, sz in { -1, 1 } do
						lowest = math.min(lowest, cf:PointToWorldSpace(half * Vector3.new(sx, sy, sz)).Y)
					end
				end
			end
		end
	end
	local legs: { Leg } = {}
	local hipY = -math.huge
	for _, fb in { "F", "B" } do
		for _, side in { "L", "R" } do
			local upper = m["Leg" .. fb .. "U" .. side]
			if upper then
				local lower = m["Leg" .. fb .. "L" .. side]
				local p0 = rest[upper.Part0 :: BasePart] or CFrame.identity
				local hip = (p0 * upper.C0).Position
				local knee = if lower then (rest[upper.Part1 :: BasePart] * lower.C0).Position else hip
				-- Tobillo: la base de la caña en reposo. Las patas pueden estar dobladas en reposo (muslo
				-- adelante, caña atrás) siempre que el tobillo quede debajo de la cadera.
				local lowerPart = lower and lower.Part1 :: BasePart
				local ankle = if lowerPart and rest[lowerPart]
					then (rest[lowerPart] * CFrame.new(0, -lowerPart.Size.Y / 2, 0)).Position
					else Vector3.new(hip.X, lowest, hip.Z)
				table.insert(legs, {
					upper = upper,
					lower = lower,
					front = fb == "F",
					left = side == "L",
					hip = hip,
					a = (hip - knee).Magnitude,
					b = (knee - ankle).Magnitude,
					D0 = (hip - ankle).Magnitude,
					shorten = newSpring(),
					swing = 0,
					plantW = newSpring(),
					wasStance = true,
					lastStep = 0,
					foot = m["Foot" .. side],
					-- Rodilla detrás de la línea cadera-tobillo (+Z es atrás): pata de ave.
					flex = if knee.Z > (hip.Z + ankle.Z) / 2 + 0.05 then -1 else 1,
				})
				hipY = math.max(hipY, hip.Y)
			end
		end
	end
	self.legs = legs
	self.legLen = math.max(0.5, hipY - lowest)
	-- Altura del vientre (base de la pieza donde nacen las patas): si la cadera está metida arriba en el
	-- torso, al acostarse baja el vientre hasta las patas plegadas, no la cadera.
	local body = if #legs > 0 then legs[1].upper.Part0 :: BasePart else nil
	self.bellyY = if body and rest[body] then rest[body].Position.Y - body.Size.Y / 2 - lowest else nil
	self.groundOffset = -lowest -- altura de la Root sobre el piso en reposo
	local hipCenter = Vector3.zero
	for _, leg in legs do
		hipCenter += leg.hip / #legs
	end
	self.hipCenter = Vector3.new(hipCenter.X, lowest, hipCenter.Z) -- punto de giro al inclinarse
	self.ground = { dy = newSpring(), pitch = newSpring(), roll = newSpring() }
	table.insert(ignored, model)
	groundParams.FilterDescendantsInstances = ignored
	self.bodyLen = if self.spine then (self.spine.Part1 :: BasePart).Size.Z else 3

	-- Cuello y cabeza, de la base a la punta.
	local neck = {}
	for _, n in { "Neck1", "Neck", "Neck2", "Head" } do
		if m[n] then
			table.insert(neck, m[n])
		end
	end
	self.neck = neck

	-- Boca en estrella (Grieta): pétalos que respiran, mastican, se cierran al dormir y muerden.
	local petals = {}
	for i = 1, 8 do
		if m["Petal" .. i] then
			table.insert(petals, m["Petal" .. i])
		end
	end
	self.petals = petals
	-- Segunda articulación de cada pétalo (la punta), si la especie la tiene.
	local tips = {}
	for i = 1, 8 do
		if m["PetalTip" .. i] then
			table.insert(tips, m["PetalTip" .. i])
		end
	end
	self.petalTips = tips

	-- Apéndices con inercia.
	local tail = {}
	for i = 1, 8 do
		if m["Tail" .. i] then
			table.insert(tail, m["Tail" .. i])
		end
	end
	self.chains = {}
	for _, c in
		{
			newChain(tail, "back", { 1.6, 1.4, 1.2, 1.05 }, 0.42),
			newChain({ m.Ant1L, m.Ant2L } :: any, "up", { 3.2, 3.8 }, 0.28),
			newChain({ m.Ant1R, m.Ant2R } :: any, "up", { 3.0, 3.6 }, 0.28),
			newChain({ m.Beard1, m.Beard2 } :: any, "down", { 1.8, 2.2 }, 0.35),
		}
	do
		if c then
			table.insert(self.chains, c)
		end
	end

	-- Estado del movimiento. vis1/vis2: posición suavizada de la Root (el servidor la manda a saltos).
	self.prevCF = root.CFrame
	self.vis1 = root.CFrame
	self.vis2 = root.CFrame
	self.speed = newSpring()
	self.yawRate = newSpring()
	self.move = newSpring() -- 0 = quieto, 1 = andando
	self.phase = 0
	self.drop = { front = newSpring(), back = newSpring() }
	self.look = { yaw = newSpring(), pitch = newSpring(), tyaw = 0, tpitch = 0, next = 0 }
	self.rng = Random.new(model:GetAttribute("Seed") :: number? or math.random(1, 1e6))
	self.t = self.rng:NextNumber(0, 100) -- desfase para que no respiren todas a la vez
	self.egg = { next = 2, start = -10 }
	self.action = { name = nil :: string?, id = nil :: number?, t = 0, eat = newSpring() }
	self.gallop = 0
	self.tailYaw, self.tailPitch, self.whip = 0, 0, 0
	self.pose = {
		rest = newSpring(),
		sleep = newSpring(),
		dig = newSpring(),
		air = newSpring(),
		front = 0,
		back = 0,
		wasAir = false,
	}
	self.breathPhase = 0
	self.jumpCrouch = 0
	self.onEvent = nil :: ((string, any) -> ())?
	self.nextSnort = self.rng:NextNumber(5, 12)
	self.prevSpeed = 0
	self.skidAt = 0
	self.vy = 0
	self.airPitch = newSpring()
	-- Acostado: el cuerpo baja hasta que las patas plegadas quedan apoyadas.
	local thick = if #legs > 0 then (legs[1].upper.Part1 :: BasePart).Size.Z else 1
	self.lieDrop = math.max(0, math.min(self.legLen, self.bellyY or math.huge) - thick * 0.5)
	local l1 = legs[1]
	if l1 and l1.flex < 0 and l1.lower then
		-- Pata de ave acostada: muslo a 45° atrás con la rodilla en el piso y la caña acostada adelante.
		local shin = l1.lower.Part1 :: BasePart
		self.lieDrop = math.max(0, self.legLen - (l1.a * math.cos(math.rad(45)) + shin.Size.Z * 0.5))
	end
	return self
end

-- Triángulo cadera-rodilla-tobillo con lados a (muslo), b (caña) y d (cadera-tobillo):
-- ángulo en la rodilla y ángulo en la cadera entre el muslo y la línea al tobillo.
local function kneeAngle(a: number, b: number, d: number): number
	return math.acos(math.clamp((a * a + b * b - d * d) / (2 * a * b), -1, 1))
end
local function hipAngle(a: number, b: number, d: number): number
	return math.acos(math.clamp((a * a + d * d - b * b) / (2 * a * d), -1, 1))
end

-- Cuánto girar cadera y rodilla (respecto del reposo) para que la pata mida d.
local function legIK(leg: Leg, d: number): (number, number)
	local a, b = leg.a, leg.b
	d = math.clamp(d, math.abs(a - b) + 0.05, a + b)
	return hipAngle(a, b, d) - hipAngle(a, b, leg.D0), kneeAngle(a, b, d) - kneeAngle(a, b, leg.D0)
end

-- Avisa un momento de la animación (sonidos y partículas los pone el cliente).
function CreatureAnimator:_emit(name: string, pos: Vector3, extra: { [string]: any }?)
	local cb = self.onEvent
	if cb then
		local ev = { pos = pos, size = self.legLen }
		if extra then
			for k, v in extra do
				ev[k] = v
			end
		end
		cb(name, ev)
	end
end

local function footOf(leg: Leg): Vector3?
	local p = leg.lower and leg.lower.Part1 :: BasePart
	return if p then (p.CFrame * CFrame.new(0, -p.Size.Y / 2, 0)).Position else nil
end

-- Pose de una pata para su fase u (0..1): apoyo (barre hacia atrás) y vuelo (sube la caña y vuelve).
local function legPose(u: number, duty: number, amp: number): (number, number)
	if u < duty then
		local k = u / duty
		return amp * (1 - 2 * k), 0
	end
	local k = (u - duty) / (1 - duty)
	return -amp + 2 * amp * smooth(k), -math.sin(math.pi * k) * (0.5 + amp)
end

function CreatureAnimator:_locomotion(dt: number)
	local cf = self.vis2 :: CFrame
	local delta = (self.prevCF :: CFrame):ToObjectSpace(cf)
	self.prevCF = cf
	local fwd = -delta.Position.Z / dt -- la criatura mira a -Z
	local _, dyaw = delta:ToEulerAnglesYXZ()
	step(self.speed, fwd, 3, 1, dt)
	step(self.yawRate, dyaw / dt, 2.5, 1, dt)

	local L = self.legLen
	local s = math.abs(self.speed.x)
	local turn = math.abs(self.yawRate.x) * L * 0.6 -- girar en el lugar también mueve las patas
	local gaitSpeed = s + turn
	step(self.move, if gaitSpeed > 0.15 * L then 1 else 0, 1.6, 1, dt)

	-- Paso -> trote -> galope (sprint) según la velocidad relativa al largo de pata.
	local trot = math.clamp((s / L - 1.1) / 0.9, 0, 1)
	local gallop = math.clamp((s / L - 3.6) / 0.9, 0, 1)
	self.gallop = gallop
	local amp = lerp(lerp(0.26, 0.5, math.clamp(gaitSpeed / (3 * L), 0, 1)), 0.62, gallop)
	local duty = lerp(lerp(0.66, 0.5, trot), 0.36, gallop)
	local stride = 2 * L * math.sin(amp) / duty -- avance del cuerpo por ciclo sin patinar
	local dir = if self.speed.x < -0.05 then -1 else 1
	self.phase = (self.phase + dir * gaitSpeed / stride * dt) % 1

	local move = self.move.x
	local drops = { front = 1, back = 1 }
	for _, leg in self.legs :: { Leg } do
		-- Caminata: trasera izq, delantera izq, trasera der, delantera der. Trote: diagonales juntas.
		local walkOff = (if leg.front then 0.25 else 0) + (if leg.left then 0 else 0.5)
		local trotOff = if leg.front == leg.left then 0.5 else 0
		-- Galope: las traseras casi juntas y después las delanteras casi juntas.
		local galOff = if self.biped
			then (if leg.left then 0 else 0.5)
			else (if leg.front then 0.5 else 0) + (if leg.left then 0 else 0.12)
		local u = (self.phase + lerp(lerp(walkOff, trotOff, trot), galOff, gallop)) % 1
		local hip, knee = legPose(u, duty, amp)
		leg.swing = hip * self.move.x
		hip *= move
		knee *= move
		-- IK: acortar la pata doblando la rodilla y girar la cadera para que el pie quede bajo ella;
		-- además se descuenta la inclinación del cuerpo para que la pata quede vertical.
		local ikHip, ikKnee = 0, 0
		local e = leg.shorten.x
		if leg.lower and e > 0.01 then
			ikHip, ikKnee = legIK(leg, leg.D0 - e)
		end
		local fl = leg.flex
		ikHip *= fl
		ikKnee *= fl
		local tilt = self.ground.pitch.x + (if leg.front then self.lastChestPitch or 0 else 0)
		-- La rodilla dobla hacia atrás en el vuelo; un poco más en las traseras.
		local hipA = hip + ikHip
		local kneeA = knee * (if leg.front then 1 else 1.2) * fl + ikKnee
		local pose = self.pose
		-- Acostado: delanteras estiradas hacia adelante, traseras plegadas debajo.
		local lie = if leg.front then pose.front else pose.back
		if lie > 0 then
			-- Pata de ave: muslo hacia atrás y caña acostada en el piso hacia adelante.
			-- (reposo -30° y +55°: el muslo pasa a -45° y la caña a 90°, horizontal hacia adelante).
			hipA = lerp(hipA, if leg.front then 1.45 elseif fl < 0 then -0.26 else 1.3, lie)
			kneeA = lerp(kneeA, if leg.front then 0 elseif fl < 0 then 1.4 else -2.6, lie)
		end
		-- Excavar: la delantera derecha rasca el suelo hacia atrás; la otra delantera y las traseras
		-- se afirman flexionadas.
		local dig = pose.dig.x
		if dig > 0.01 then
			local dg = self.t * 7
			if leg.front and not leg.left then
				hipA = lerp(hipA, 0.55 + 0.5 * math.sin(dg), dig)
				kneeA = lerp(kneeA, -0.7 - 0.6 * math.max(0, math.sin(dg + 1.2)), dig)
			elseif leg.front then
				hipA += 0.1 * dig
				kneeA -= 0.25 * dig
			else
				hipA += 0.25 * dig * fl
				kneeA -= 0.45 * dig * fl
			end
		end
		-- Salto, carga: las traseras se flexionan para empujar.
		local jc = self.jumpCrouch
		if jc > 0.01 then
			if leg.front then
				kneeA -= 0.3 * jc
			else
				hipA += 0.55 * jc * fl
				kneeA -= 1.1 * jc * fl
			end
		end
		-- En el aire: subiendo, delanteras recogidas y traseras estiradas atrás (recién empujaron);
		-- bajando, delanteras estiradas para recibir el suelo y traseras que se recogen.
		local air = pose.air.x
		if air > 0.01 then
			local up = math.clamp(0.5 + self.vy * 0.05, 0, 1) -- 1 subiendo, 0 bajando, suave en la cima
			local h = if leg.front then lerp(0.3, 0.6, up) else lerp(0.2, -0.5, up)
			local k = if leg.front then lerp(-0.35, -1.2, up) else lerp(-0.8, -0.4, up) * fl
			hipA = lerp(hipA, h, air)
			kneeA = lerp(kneeA, k, air)
		end
		local hipX, hipZ = hipA - tilt, -self.ground.roll.x
		-- Pies fijos: quieta (atacando, excavando, respirando), cada pie apoyado se queda en su lugar
		-- del mundo y la pata se acomoda con IK aunque el cuerpo se mueva. Así no patinan.
		local digger = dig > 0.01 and leg.front and not leg.left
		local planted = move < 0.15 and air < 0.05 and lie < 0.05 and jc < 0.05 and not digger
		step(leg.plantW, if planted then 1 else 0, 6, 1, dt)
		local lowerPart = leg.lower and leg.lower.Part1 :: BasePart
		if planted and not leg.plant and lowerPart then
			leg.plant = (lowerPart.CFrame * CFrame.new(0, -lowerPart.Size.Y / 2, 0)).Position
		elseif not planted then
			leg.plant = nil
		end
		local pw = leg.plantW.x
		local hipT = CFrame.Angles(hipX, 0, hipZ)
		if pw > 0.01 and leg.plant and leg.lower then
			local hipCF = (leg.upper.Part0 :: BasePart).CFrame * leg.upper.C0
			local p = hipCF:PointToObjectSpace(leg.plant :: Vector3)
			-- Si el cuerpo giró tanto que el pie quedaría muy estirado, lo vuelve a apoyar bajo la cadera.
			local D0 = leg.D0
			if Vector3.new(p.X, 0, p.Z).Magnitude > 0.45 * D0 or p.Y > -0.3 * D0 then
				leg.plant = (hipCF * CFrame.new(0, -D0, 0)).Position
				p = Vector3.new(0, -D0, 0)
			end
			-- Apuntar la pata al pie con una rotación real (pitch y roll por separado fallan con
			-- ángulos grandes) y doblar la rodilla para que el largo coincida.
			local toFoot = p.Unit
			local axis = Vector3.new(0, -1, 0):Cross(toFoot)
			local aim = if axis.Magnitude > 1e-4
				then CFrame.fromAxisAngle(axis.Unit, math.acos(math.clamp(-toFoot.Y, -1, 1)))
				else CFrame.identity
			local plantHip, plantKnee = legIK(leg, p.Magnitude)
			local plantedCF = aim * CFrame.Angles(plantHip * fl, 0, 0)
			hipT = hipT:Lerp(plantedCF, pw)
			kneeA = lerp(kneeA, plantKnee * fl, pw)
		end
		leg.upper.Transform = hipT
		if leg.lower then
			leg.lower.Transform = CFrame.Angles(kneeA, 0, 0)
			-- Pie aparte (bípeda): se mantiene plano contra el suelo aunque muslo y caña giren.
			if leg.foot then
				local hx = hipT:ToEulerAnglesXYZ()
				leg.foot.Transform = CFrame.Angles(-(hx + kneeA) * (1 - 0.6 * self.pose.air.x), 0, 0)
			end
		end
		local stance = u < duty
		-- Pisada: solo avanzando de verdad y con un mínimo entre pisadas de la misma pata (sin esto, el
		-- límite apoyo/vuelo titilaba y sonaban decenas de pasos por segundo).
		local stepping = s > 0.3 * L and self.t - leg.lastStep > 0.22
		if stance and not leg.wasStance and stepping and move > 0.4 and self.pose.air.x < 0.3 then
			leg.lastStep = self.t
			local fp = footOf(leg)
			if fp then
				self:_emit("Pisada", fp, { speed = s })
			end
		end
		leg.wasStance = stance
		if u < duty then
			-- La pata de apoyo más vertical sostiene el cuerpo.
			local key = if leg.front then "front" else "back"
			drops[key] = math.min(drops[key], 1 - math.cos(hip))
		end
	end
	local function dropOf(v: number): number
		return if v == 1 then 0 else v * L
	end
	step(self.drop.front, dropOf(drops.front), 6, 0.8, dt)
	step(self.drop.back, dropOf(drops.back), 6, 0.8, dt)
	-- Frenada fuerte después de correr: polvo hacia adelante.
	local decel = (self.prevSpeed - s) / dt
	self.prevSpeed = s
	if self.gallop > 0.5 and self.prevSpeed > 2.5 * L and decel > 8 * L and self.t - self.skidAt > 1.5 then
		self.skidAt = self.t
		local ahead = (self.vis2 :: CFrame).LookVector
		self:_emit("Frenada", (self.vis2 :: CFrame).Position + ahead * L * 0.8, { dir = ahead })
	end
	return move, trot
end

-- Postura pedida por atributo. rest: 0 = de pie, 1 = acostado. front/back: cuánto bajó cada mitad.
function CreatureAnimator:_posture(dt: number)
	local p = self.pose
	local model = self.model :: Model
	local posture = model:GetAttribute("Postura")
	local sleeping = posture == "Durmiendo"
	local lying = sleeping or posture == "Acostado"
	-- Dormido: primero se despierta (lento) y recién después se levanta.
	step(p.sleep, if sleeping then 1 else 0, if sleeping then 0.22 else 0.3, 1, dt)
	step(p.rest, if lying or p.sleep.x > 0.35 then 1 else 0, 0.38, 1, dt)
	local r = math.clamp(p.rest.x, 0, 1)
	-- Se acuesta primero adelante y se levanta primero atrás (como una vaca).
	p.front = smooth(math.clamp(r / 0.6, 0, 1))
	p.back = smooth(math.clamp((r - 0.4) / 0.6, 0, 1))
	step(p.dig, if model:GetAttribute("Accion") == "Excavar" then 1 else 0, 2, 1, dt)
end

-- Ajuste al terreno: altura del suelo bajo cada cadera, plano del cuerpo y cuánto acortar cada pata.
function CreatureAnimator:_ground(dt: number)
	local legs = self.legs :: { Leg }
	if #legs < 2 then
		return
	end
	local cf = self.vis2 :: CFrame
	local L = self.legLen
	local nominal = cf.Y - self.groundOffset
	local g = {}
	for i, leg in legs do
		-- El suelo se busca donde está el pie (adelante o atrás de la cadera según el paso).
		local wp = cf:PointToWorldSpace(leg.hip + Vector3.new(0, 0, -L * math.sin(leg.swing)))
		local hit = workspace:Raycast(wp + Vector3.new(0, L, 0), Vector3.new(0, -3 * L, 0), groundParams)
		g[i] = if hit then hit.Position.Y else nominal
	end
	-- Promedios adelante/atrás e izquierda/derecha -> inclinación del cuerpo.
	local F, B, Lf, R, nF, nB, nL, nR = 0, 0, 0, 0, 0, 0, 0, 0
	local zF, zB, xL, xR = 0, 0, 0, 0
	for i, leg in legs do
		if leg.front then
			F, nF, zF = F + g[i], nF + 1, zF + leg.hip.Z
		else
			B, nB, zB = B + g[i], nB + 1, zB + leg.hip.Z
		end
		if leg.left then
			Lf, nL, xL = Lf + g[i], nL + 1, xL + leg.hip.X
		else
			R, nR, xR = R + g[i], nR + 1, xR + leg.hip.X
		end
	end
	-- En el aire: el suelo quedó lejos de todas las patas.
	local p = self.pose
	local highest = -math.huge
	for _, y in g do
		highest = math.max(highest, y)
	end
	step(p.air, if nominal - highest > 0.25 * L then 1 else 0, 4, 1, dt)
	local air = math.clamp(p.air.x, 0, 1)
	if p.wasAir and air < 0.5 then
		-- Aterrizaje: el cuerpo amortigua.
		self.drop.back.v += 0.5 * L
		self.drop.front.v += 0.6 * L
		self:_emit("Caida", Vector3.new(cf.X, highest, cf.Z))
	end
	p.wasAir = air > 0.5
	local onGround = (1 - air) * (1 - math.max(p.front, p.back))
	-- Bípeda (sin patas delanteras): la pendiente adelante-atrás se mide con un rayo extra adelante.
	local biped = nF == 0
	if biped then
		local span = math.max(1.5, self.bodyLen * 0.6)
		local hz = zB / nB
		local probe = cf:PointToWorldSpace(Vector3.new(self.hipCenter.X, 0, hz - span))
		local hit = workspace:Raycast(probe + Vector3.new(0, L, 0), Vector3.new(0, -3 * L, 0), groundParams)
		F, nF, zF = if hit then hit.Position.Y else nominal, 1, hz - span
	end
	F, B, Lf, R = F / nF, B / nB, Lf / nL, R / nR
	zF, zB, xL, xR = zF / nF, zB / nB, xL / nL, xR / nR
	local slopeF = (F - B) / math.max(0.5, zB - zF) -- sube hacia adelante (-Z)
	local slopeL = (Lf - R) / math.max(0.5, xR - xL) -- sube hacia la izquierda (-X)
	-- Bípeda: el cuerpo se apoya donde están las patas (atrás del rayo de adelante).
	local gc = if biped then B else (F + B) / 2
	local zc, xc = if biped then zB else (zF + zB) / 2, (xL + xR) / 2
	-- Lo que el plano no explica lo absorben las patas: el cuerpo baja hasta que la pata con el
	-- suelo más bajo llegue estirada, y las demás doblan la rodilla.
	local lower = 0
	local resid = {}
	for i, leg in legs do
		resid[i] = g[i] - (gc + slopeF * (zc - leg.hip.Z) + slopeL * (xc - leg.hip.X))
		lower = math.max(lower, -resid[i])
	end
	for i, leg in legs do
		step(leg.shorten, math.min(resid[i] + lower, 0.6 * leg.D0) * onGround, 8, 1, dt)
	end
	step(self.ground.dy, (gc - nominal - lower) * (1 - air), 8, 1, dt)
	step(self.ground.pitch, math.clamp(math.atan(slopeF), -0.5, 0.5) * (1 - air), 6, 1, dt)
	step(self.ground.roll, math.clamp(-math.atan(slopeL), -0.35, 0.35) * (1 - air), 6, 1, dt)
end

function CreatureAnimator:_lookAround(dt: number, move: number)
	local look = self.look
	local rng = self.rng :: Random
	local owner = (self.model :: Model):GetAttribute("Jugador")
	if owner then
		-- Criatura de un jugador: la cabeza mira hacia donde mira su cámara (el local la lee directo,
		-- los demás reciben el atributo Mirar). Si la cámara mira para atrás, gira hasta donde puede.
		local yawT, pitchT = 0, 0
		local cam = workspace.CurrentCamera
		if owner == LOCAL_ID and cam then
			local dir = (self.vis2 :: CFrame):VectorToObjectSpace(cam.CFrame.LookVector)
			yawT = math.atan2(-dir.X, -dir.Z)
			pitchT = math.asin(math.clamp(dir.Y, -1, 1)) + 0.25 -- la cámara mira un poco hacia abajo
		else
			local m = (self.model :: Model):GetAttribute("Mirar")
			if typeof(m) == "Vector2" then
				yawT, pitchT = m.X, m.Y
			end
		end
		look.tyaw = math.clamp(yawT, -1.3, 1.3)
		look.tpitch = math.clamp(pitchT, -0.6, 0.5)
		step(look.yaw, look.tyaw, 2, 1, dt)
		step(look.pitch, look.tpitch, 2, 1, dt)
		return
	end
	look.next -= dt
	if look.next <= 0 then
		if move > 0.5 then
			look.tyaw, look.tpitch = rng:NextNumber(-0.15, 0.15), rng:NextNumber(-0.1, 0.05)
			look.next = rng:NextNumber(1.5, 3)
		else
			look.tyaw, look.tpitch = rng:NextNumber(-0.7, 0.7), rng:NextNumber(-0.3, 0.2)
			look.next = rng:NextNumber(1.8, 4.5)
		end
	end
	step(look.yaw, look.tyaw, 0.9, 0.95, dt)
	step(look.pitch, look.tpitch, 0.9, 0.95, dt)
end

function CreatureAnimator:_chains(dt: number)
	for _, c in self.chains :: { Chain } do
		local cur = c.base.CFrame
		local rel = c.prev:ToObjectSpace(cur)
		c.prev = cur
		-- La entrada se filtra: los micro-saltos del paso hacían vibrar antenas y barba.
		local rx0, ry0, rz0 = rel:ToEulerAnglesXYZ()
		local alpha = 1 - math.exp(-dt * 12)
		c.fr = (c.fr or Vector3.zero):Lerp(Vector3.new(rx0, ry0, rz0), alpha)
		c.fd = (c.fd or Vector3.zero):Lerp(rel.Position, alpha)
		local rx, ry, rz = c.fr.X, c.fr.Y, c.fr.Z
		local d = c.fd :: Vector3
		local move = self.move.x
		local damp = lerp(c.damp, if c.kind == "back" then 0.55 else 0.75, move)
		local rest = self.pose.rest.x
		local prevA, prevB = 0, 0
		for i, motor in c.motors do
			local a, b, r = c.a[i], c.b[i], c.r[i]
			-- Inercia: la pieza se queda donde estaba en el mundo mientras la base se mueve.
			if c.kind == "up" then
				a.x += -d.Z / r - rx
				b.x += d.X / r - rz
			elseif c.kind == "down" then
				a.x += d.Z / r - rx
				b.x += -d.X / r - rz
			else
				a.x += d.Y / r - rx
				b.x += -d.X / r - ry
			end
			-- Cada pieza tiende a alinearse con la anterior; la cola además ondula suave.
			local pose = self.pose
			local wave = if c.kind == "back" then math.sin(self.t * 1.3 - i * 0.7) * 0.05 * i * (1 - 0.8 * rest) else 0
			local sag = if c.kind == "back" then 0.015 * i else 0
			if c.kind == "back" then
				-- Acostada, cada bloque de la cola se apoya en el suelo que tiene abajo (sigue el terreno);
				-- dormida además se enrosca hacia un costado.
				if rest > 0.01 then
					local jointW = ((motor.Part0 :: BasePart).CFrame * motor.C0).Position
					local hit = workspace:Raycast(jointW + Vector3.new(0, 2, 0), Vector3.new(0, -30, 0), groundParams)
					if hit then
						local seg = motor.Part1 :: BasePart
						local h = jointW.Y - hit.Position.Y - seg.Size.Y * 0.5
						local lieOnGround = math.asin(math.clamp(h / seg.Size.Z, -0.6, 1))
						-- Corrección medida: si la punta del bloque igual queda en el aire (cola enroscada y
						-- cuerpo de costado), se va bajando hasta tocar.
						local tip = (seg.CFrame * CFrame.new(0, -seg.Size.Y / 2, seg.Size.Z / 2)).Position
						local under =
							workspace:Raycast(tip + Vector3.new(0, 2, 0), Vector3.new(0, -30, 0), groundParams)
						c.fix = c.fix or {}
						local fix = c.fix[i] or 0
						if under then
							fix = math.clamp(
								fix + math.clamp(tip.Y - under.Position.Y - 0.25, -1, 1) * dt * 1.2,
								-0.6,
								0.8
							)
						end
						c.fix[i] = fix
						sag = lerp(sag, lieOnGround - prevA + fix, rest)
					end
				elseif c.fix then
					c.fix[i] = 0 -- de pie: sin corrección
				end
				wave += 0.75 * pose.sleep.x -- se enrosca al costado del cuerpo, hasta la cabeza
			elseif c.kind == "up" then
				sag += 0.5 * pose.sleep.x -- antenas caídas al dormir
			end
			local freq = c.freq[i]
			local limit = 0.8
			if c.kind == "back" then
				-- Coletazo: se mueve la base y el resto sigue con retraso (efecto látigo).
				freq *= 1 + 2.2 * self.whip
				if i == 1 then
					wave += self.tailYaw
					sag += self.tailPitch
					limit = 1.4
				end
			end
			step(a, prevA + sag, freq, damp, dt)
			step(b, prevB + wave, freq, damp, dt)
			a.x = math.clamp(a.x, prevA - limit, prevA + limit)
			b.x = math.clamp(b.x, prevB - limit, prevB + limit)
			local la, lb = a.x - prevA, b.x - prevB
			-- Cola: primero gira hacia el costado y después inclina sobre su propio eje (con la cola enroscada,
			-- inclinar sobre el eje del bloque anterior no la bajaba al suelo).
			motor.Transform = if c.kind == "back"
				then CFrame.fromEulerAnglesYXZ(la, lb, 0)
				else CFrame.Angles(la, 0, lb)
			prevA, prevB = a.x, b.x
		end
	end
end

-- Acciones que pide el servidor. Devuelve el peso de "comer" y los ángulos del coletazo.
type ActionOut = { bodyYaw: number, neckYaw: number, neckPitch: number, lunge: number, petal: number? }

function CreatureAnimator:_action(dt: number): (number, ActionOut)
	local a = self.action
	local model = self.model :: Model
	local name = model:GetAttribute("Accion") :: string?
	local id = model:GetAttribute("AccionId") :: number?
	if name ~= a.name or id ~= a.id then
		a.name, a.id, a.t = name, id, 0
	end
	local before = a.t
	a.t += dt
	local function crossed(at: number): boolean
		return before < at and a.t >= at
	end
	local m = self.m
	if name == "Coletazo" then
		local tipMotor = m.Tail4 or m.Tail3 or m.Tail2 or m.Tail1
		local tip = tipMotor and (tipMotor.Part1 :: BasePart).Position
		if tip and crossed(0.45) then
			self:_emit("Latigazo", tip)
		elseif tip and crossed(0.6) then
			local fwd = (self.vis2 :: CFrame).LookVector
			self:_emit("ColaGolpe", tip, { dir = -fwd })
		end
	elseif (name == "Cabezazo" or name == "Mordisco") and m.Head then
		local head = (m.Head.Part1 :: BasePart).Position
		if crossed(0.3) then
			self:_emit("Embestida", head)
		elseif crossed(if name == "Mordisco" then 0.45 else 0.42) then
			self:_emit("CabezaGolpe", head)
		end
	end
	step(a.eat, if name == "Comer" then 1 else 0, 0.9, 1, dt)
	-- Carga del salto: el jugador local usa su propio reloj (SaltoEn) para no esperar al servidor.
	local jumpT: number? = nil
	local localJump = model:GetAttribute("SaltoEn") :: number?
	if localJump and os.clock() - localJump < 1 then
		jumpT = os.clock() - localJump
	elseif name == "Saltar" then
		jumpT = a.t
	end
	if jumpT and jumpT >= 0.3 and jumpT - dt < 0.3 then
		self:_emit("Salto", (self.vis2 :: CFrame).Position)
	end
	self.jumpCrouch = if not jumpT
		then 0
		elseif jumpT < 0.3 then smooth(jumpT / 0.3)
		elseif jumpT < 0.45 then 1 - smooth((jumpT - 0.3) / 0.15)
		else 0

	local out: ActionOut = { bodyYaw = 0, neckYaw = 0, neckPitch = 0, lunge = 0 }
	self.tailYaw, self.tailPitch, self.whip = 0, 0, 0
	if name == "Coletazo" then
		-- Carga hacia un lado, látigo hacia el otro y vuelta. El lado alterna en cada golpe.
		local side = if (id or 0) % 2 == 0 then 1 else -1
		local k = a.t
		local tail, body, neck, lift
		if k < 0.45 then
			local s = smooth(k / 0.45)
			tail, body, neck, lift = 0.9 * s, -0.12 * s, 0.35 * s, -0.25 * s
		elseif k < 0.7 then
			local s = smooth((k - 0.45) / 0.25)
			tail, body, neck, lift = lerp(0.9, -1.25, s), lerp(-0.12, 0.2, s), lerp(0.35, -0.1, s), lerp(-0.25, 0.05, s)
		elseif k < 1.5 then
			local s = smooth((k - 0.7) / 0.8)
			tail, body, neck, lift = lerp(-1.25, 0, s), lerp(0.2, 0, s), lerp(-0.1, 0, s), lerp(0.05, 0, s)
		else
			tail, body, neck, lift = 0, 0, 0, 0
		end
		self.tailYaw, self.tailPitch = tail * side, lift
		self.whip = if k < 1.5 then 1 else 0
		out.bodyYaw, out.neckYaw = body * side, neck * side
	elseif name == "Cabezazo" then
		-- Echa la cabeza atrás, embiste hacia adelante y abajo, y vuelve.
		local k = a.t
		local neckP, lunge
		if k < 0.3 then
			local s = smooth(k / 0.3)
			neckP, lunge = 0.45 * s, -0.25 * s
		elseif k < 0.45 then
			local s = smooth((k - 0.3) / 0.15)
			neckP, lunge = lerp(0.45, -0.7, s), lerp(-0.25, 1, s)
		elseif k < 1 then
			local s = smooth((k - 0.45) / 0.55)
			neckP, lunge = lerp(-0.7, 0, s), lerp(1, 0, s)
		else
			neckP, lunge = 0, 0
		end
		out.neckPitch, out.lunge = neckP, lunge * self.legLen * 0.25
	elseif name == "Mordisco" then
		-- Abre la boca del todo (pétalos hacia atrás), se lanza y la cierra de golpe; después vuelve.
		local k = a.t
		local neckP, lunge, petal
		if k < 0.3 then
			local s = smooth(k / 0.3)
			neckP, lunge, petal = 0.2 * s, -0.2 * s, lerp(-0.75, 0.45, s)
		elseif k < 0.45 then
			local s = smooth((k - 0.3) / 0.15)
			neckP, lunge, petal = lerp(0.2, -0.35, s), lerp(-0.2, 1.1, s), lerp(0.45, -1.35, s)
		elseif k < 1.1 then
			local s = smooth((k - 0.45) / 0.65)
			neckP, lunge, petal = lerp(-0.35, 0, s), lerp(1.1, 0, s), lerp(-1.4, -0.75, s)
		else
			neckP, lunge, petal = 0, 0, nil
		end
		out.neckPitch, out.lunge, out.petal = neckP, lunge * self.legLen * 0.25, petal
	end
	return a.eat.x, out
end

function CreatureAnimator:_egg(dt: number)
	local e = self.egg
	local rng = self.rng :: Random
	e.next -= dt
	if e.next <= 0 then
		e.start = self.t
		e.next = rng:NextNumber(2.5, 6)
		e.dir = rng:NextNumber(0, TAU)
	end
	local k = self.t - e.start
	local env = if k < 1.2 then math.sin(math.pi * k / 1.2) else 0
	local wob = math.sin(k * 16) * 0.07 * env
	local dir = e.dir or 0
	local breathe = 1 + math.sin(self.t * 2) * 0.004
	self.m.Capa1.Transform = CFrame.Angles(wob * math.cos(dir), 0, wob * math.sin(dir))
		* CFrame.new(0, (breathe - 1) * 4, 0)
end

function CreatureAnimator:update(dt: number)
	dt = math.clamp(dt, 1 / 240, 1 / 20)
	self.t += dt
	-- La Root llega del servidor a saltos (~15 por segundo): dos filtros en cascada la suavizan
	-- (unos 0.25 s de retraso) y el cuerpo se dibuja en la posición suavizada.
	local root = self.root :: BasePart
	local k = 1 - math.exp(-dt * 8)
	if (root.Position - (self.vis2 :: CFrame).Position).Magnitude > self.legLen * 2 then
		-- Teletransporte o streaming: saltar sin inercia.
		self.vis1, self.vis2, self.prevCF = root.CFrame, root.CFrame, root.CFrame
		for _, c in self.chains :: { Chain } do
			c.prev = c.base.CFrame
		end
	end
	if root.Anchored then
		self.vis1 = (self.vis1 :: CFrame):Lerp(root.CFrame, k)
		self.vis2 = (self.vis2 :: CFrame):Lerp(self.vis1, k)
	else
		-- Personaje con física (jugador): la posición ya llega suave.
		self.vis1, self.vis2 = root.CFrame, root.CFrame
	end
	if self.isEgg then
		self:_egg(dt)
		return
	end
	self:_posture(dt)
	self:_ground(dt)
	local move, trot = self:_locomotion(dt)
	self:_lookAround(dt, move)
	local eat, act = self:_action(dt)
	local gallop = self.gallop
	local L = self.legLen
	local t = self.t
	local yawRate = math.clamp(self.yawRate.x, -2.5, 2.5)

	-- Cuerpo: baja con las patas, rola con el paso, respira y cambia el peso en reposo.
	local still = 1 - move
	local pose = self.pose
	local rest, sleep = pose.rest.x, pose.sleep.x
	-- Respiración: más lenta y profunda acostada y dormida (fase acumulada: sin saltos al cambiar).
	local prevBreath = self.breathPhase
	self.breathPhase += dt * TAU * lerp(0.28, 0.17, sleep)
	local headPos = if self.m.Head then (self.m.Head.Part1 :: BasePart).Position else root.Position
	if sleep > 0.7 and math.floor(prevBreath / TAU) ~= math.floor(self.breathPhase / TAU) then
		self:_emit("RespiraDormida", headPos)
	end
	-- Quieta y despierta, cada tanto resopla.
	self.nextSnort -= dt
	if self.nextSnort <= 0 then
		self.nextSnort = self.rng:NextNumber(8, 18)
		if still > 0.8 and sleep < 0.1 then
			self:_emit("Resoplido", headPos)
		end
	end
	local breath = math.sin(self.breathPhase)
	local dig = pose.dig.x
	local dg = t * 7
	local jc = self.jumpCrouch
	self.vy = if root.Anchored then 0 else root.AssemblyLinearVelocity.Y
	local air = pose.air.x
	local backDrop = self.drop.back.x + pose.back * self.lieDrop + 0.25 * L * jc + 0.06 * L * dig
	local frontDrop = self.drop.front.x
		+ pose.front * self.lieDrop
		+ 0.06 * L * jc
		+ (if self.biped then 0.45 else 0.12) * L * dig -- bípeda: baja el pecho para llegar al suelo con el hocico
	local stepRoll = math.sin(self.phase * TAU) * 0.035 * move * (1 - trot)
	local shift = math.sin(t * 0.37) * 0.025 * still
	local gp = math.sin(self.phase * TAU) -- ciclo del galope
	local bodyY = -backDrop + breath * (0.012 + 0.01 * rest) * L * still + gp * 0.05 * L * gallop - 0.1 * L * sleep
	-- Se inclina un poco hacia adelante al trotar; al galopar se mece adelante-atrás.
	local bodyPitch = -0.04 * trot * move + gp * 0.06 * gallop
	-- En el aire la nariz sigue la trayectoria: arriba al subir, abajo al caer.
	step(self.airPitch, math.clamp(self.vy * 0.025, -0.3, 0.35) * air, 3, 1, dt)
	bodyPitch += self.airPitch.x
	if self.body then
		local c0 = self.body.C0
		local visual = c0:Inverse() * root.CFrame:ToObjectSpace(self.vis2 :: CFrame) * c0
		-- Inclinación del terreno, girando alrededor del centro de las caderas a nivel del piso.
		local pivot = c0:PointToObjectSpace(self.hipCenter)
		-- Dormida se recuesta de costado (la panza hacia el lado donde enrosca la cola).
		local slope = CFrame.new(pivot)
			* CFrame.Angles(self.ground.pitch.x, 0, self.ground.roll.x + 0.25 * sleep)
			* CFrame.new(-pivot)
		-- Excavando, el cuerpo acompaña cada rascada (atrás-adelante y de costado).
		local digRock = math.sin(dg) * dig
		-- Cada rascada (la pata va hacia atrás) tira tierra.
		local digSin = math.sin(dg)
		if dig > 0.6 and (self.lastDigSin or 0) > 0 and digSin <= 0 and self.biped and self.m.Head then
			local head = (self.m.Head.Part1 :: BasePart).Position
			self:_emit("Rascada", head - Vector3.new(0, 1, 0), { dir = -(self.vis2 :: CFrame).LookVector })
		elseif dig > 0.6 and (self.lastDigSin or 0) > 0 and digSin <= 0 then
			for _, leg in self.legs :: { Leg } do
				if leg.front and not leg.left then
					local fp = footOf(leg)
					if fp then
						self:_emit("Rascada", fp, { dir = -(self.vis2 :: CFrame).LookVector })
					end
				end
			end
		end
		self.lastDigSin = digSin
		self.body.Transform = visual
			* CFrame.new(0, bodyY + self.ground.dy.x, -act.lunge + 0.06 * L * digRock)
			* slope
			* CFrame.Angles(bodyPitch, act.bodyYaw, stepRoll + shift - yawRate * 0.04 + 0.04 * digRock)
	end
	local chestPitch = 0
	if self.spine then
		local rel = frontDrop - backDrop
		chestPitch = -math.asin(math.clamp(rel / self.bodyLen, -0.5, 0.5)) + breath * 0.01 * still
		-- Galope: la columna se flexiona y se estira; comiendo baja el pecho.
		chestPitch += math.sin(self.phase * TAU + 1.6) * 0.1 * gallop - 0.07 * eat
		local spineYaw = yawRate * 0.12 + math.sin(self.phase * TAU) * 0.03 * move * (1 - trot)
		self.spine.Transform = CFrame.Angles(chestPitch, spineYaw, 0)
	end
	self.lastChestPitch = chestPitch

	-- Cuello y cabeza: compensan el cuerpo para que la cabeza quede estable, adelantan el giro,
	-- cabecean con el paso y miran alrededor.
	local n = #self.neck
	if n > 0 then
		local nod = math.sin(self.phase * TAU * 2) * 0.05 * move * (1 - trot * 0.5)
		local calm = (1 - 0.7 * eat) * (1 - sleep)
		-- Dormida gira la cabeza hacia la cola enroscada; excavando mira la pata que rasca.
		local yaw = self.look.yaw.x * calm + yawRate * 0.22 + act.neckYaw - 1.6 * sleep - 0.15 * dig
		local pitch = self.look.pitch.x * calm + nod - (bodyPitch + chestPitch) - self.ground.pitch.x * 0.5
		-- Acostada baja un poco la cabeza; dormida la apoya en el suelo. Excavando mira el pozo.
		pitch += breath * 0.02 * sleep + act.neckPitch
		if self.biped then
			-- Bípeda: excava con el hocico, hunde la cabeza y la mueve hozando adelante-atrás.
			pitch += dig * (-1.75 + 0.22 * math.sin(dg + 0.6))
		else
			pitch += dig * (-0.9 + 0.1 * math.sin(dg + 0.6)) -- cabeza abajo, acompaña la rascada
		end
		-- Comer: cabeza al pasto, mastica y cada tanto tira para arrancar.
		local tug = math.max(0, math.sin(t * TAU / 1.7)) ^ 6
		pitch += eat * (-1.25 + math.sin(t * 9) * 0.05 + tug * 0.3)
		local weights = if n >= 3 then { 0.35, 0.25, 0.4 } elseif n == 2 then { 0.5, 0.5 } else { 1 }
		-- Acostada baja un poco la cabeza; dormida dobla el cuello hacia abajo y deja la cabeza
		-- horizontal, apoyada en el suelo.
		local fold = if n >= 3
			then { -(0.2 * rest + 1.0 * sleep), -(0.1 * rest + 0.5 * sleep), 0.05 * rest + 0.8 * sleep }
			else { -(0.3 * rest + 0.75 * sleep) / n, -(0.3 * rest + 0.75 * sleep) / n }
		for i, motor in self.neck do
			local w = weights[i] or 0
			motor.Transform = CFrame.Angles(pitch * w + (fold[i] or 0), yaw * w, 0)
		end
	end

	-- Pétalos: entreabiertos respirando, mastican al comer, cerrados al dormir; el mordisco manda.
	local petals = self.petals :: { Motor6D }
	if #petals > 0 then
		-- De pie: semiabierta. Acostada y dormida: cerrada; acostada (despierta) se abre cada tanto.
		local closed = math.max(rest, sleep)
		local peekW = self.petalPeek or newSpring()
		self.petalPeek = peekW
		self.nextPeek = (self.nextPeek or 6) - dt
		if self.nextPeek <= 0 then
			self.nextPeek = (self.rng :: Random):NextNumber(6, 12)
			self.peekUntil = t + 1.8
		end
		step(peekW, if t < (self.peekUntil or 0) then 1 else 0, 1.2, 1, dt)
		local peek = peekW.x * math.clamp(rest - sleep, 0, 1)
		local base = lerp(lerp(-0.75, -1.4, closed), -0.8, peek)
			+ breath * 0.05 * (1 - closed)
			+ eat * 0.3 * math.sin(t * 9)
		local target = act.petal or base
		local tips = self.petalTips :: { Motor6D }
		for i, motor in petals do
			-- Tambaleo: cada pétalo se mueve solo, lento e irregular (dos ondas); dormida casi nada.
			local sway = math.sin(t * 1.3 + i * 1.3) * 0.1 + math.sin(t * 2.9 + i * 2.1) * 0.05
			-- Siempre tambalea, abierta o cerrada (dormida, un poco menos).
			local wobble = if act.petal then 0 else sway * (1 - 0.45 * sleep)
			-- Los pétalos ya vienen semicerrados en el modelo (-43°, la punta -30°): se anima respecto de eso.
			motor.Transform = CFrame.Angles(target + wobble + PETAL_REST, 0, 0)
			-- La punta acompaña con un poco de retraso visual: se curva más al cerrar y se estira al abrir.
			local tip = tips[i]
			if tip then
				local tipWobble = (math.sin(t * 1.3 + i * 1.3 - 0.8) * 0.14 + math.sin(t * 3.1 + i) * 0.05)
					* (1 - 0.45 * sleep)
				tip.Transform = CFrame.Angles(target * 0.7 + (if act.petal then 0 else tipWobble) + TIP_REST, 0, 0)
			end
		end
	end

	self:_chains(dt)
end

return CreatureAnimator
