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
--   - Acciones (atributos "Accion"/"AccionId" que pone el servidor): "Comer" y "Coletazo".
-- Funciona con cualquier especie que use los nombres de piezas de tools/creatures.py.

local CreatureAnimator = {}
CreatureAnimator.__index = CreatureAnimator

local TAU = 2 * math.pi

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
}
type Leg = {
	upper: Motor6D,
	lower: Motor6D?,
	front: boolean,
	left: boolean,
	hip: Vector3, -- cadera en el espacio de la Root, en reposo
	a: number, -- cadera a rodilla
	b: number, -- rodilla al piso
	shorten: Spring, -- cuánto tiene que acortarse para apoyar en el suelo real
	swing: number, -- ángulo de paso del último cuadro (para buscar el suelo donde está el pie)
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
	local lowest = math.huge
	for part, cf in rest do
		if part ~= root then
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
				table.insert(legs, {
					upper = upper,
					lower = lower,
					front = fb == "F",
					left = side == "L",
					hip = hip,
					a = (hip - knee).Magnitude,
					b = knee.Y - lowest,
					shorten = newSpring(),
					swing = 0,
				})
				hipY = math.max(hipY, hip.Y)
			end
		end
	end
	self.legs = legs
	self.legLen = math.max(0.5, hipY - lowest)
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
	return self
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
		local galOff = (if leg.front then 0.5 else 0) + (if leg.left then 0 else 0.12)
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
			local a, b = leg.a, leg.b
			local d = math.max(a + b - e, math.abs(a - b) + 0.05)
			local interior = math.acos(math.clamp((a * a + b * b - d * d) / (2 * a * b), -1, 1))
			local bend = math.pi - interior
			ikKnee = -bend
			ikHip = math.atan2(b * math.sin(bend), a + b * math.cos(bend))
		end
		local tilt = self.ground.pitch.x + (if leg.front then self.lastChestPitch or 0 else 0)
		leg.upper.Transform = CFrame.Angles(hip + ikHip - tilt, 0, -self.ground.roll.x)
		if leg.lower then
			-- La rodilla dobla hacia atrás en el vuelo; un poco más en las traseras.
			leg.lower.Transform = CFrame.Angles(knee * (if leg.front then 1 else 1.2) + ikKnee, 0, 0)
		end
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
	return move, trot
end

-- Ajuste al terreno: altura del suelo bajo cada cadera, plano del cuerpo y cuánto acortar cada pata.
function CreatureAnimator:_ground(dt: number)
	local legs = self.legs :: { Leg }
	if #legs < 4 then
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
	F, B, Lf, R = F / nF, B / nB, Lf / nL, R / nR
	zF, zB, xL, xR = zF / nF, zB / nB, xL / nL, xR / nR
	local slopeF = (F - B) / math.max(0.5, zB - zF) -- sube hacia adelante (-Z)
	local slopeL = (Lf - R) / math.max(0.5, xR - xL) -- sube hacia la izquierda (-X)
	local gc = (F + B) / 2
	local zc, xc = (zF + zB) / 2, (xL + xR) / 2
	-- Lo que el plano no explica lo absorben las patas: el cuerpo baja hasta que la pata con el
	-- suelo más bajo llegue estirada, y las demás doblan la rodilla.
	local lower = 0
	local resid = {}
	for i, leg in legs do
		resid[i] = g[i] - (gc + slopeF * (zc - leg.hip.Z) + slopeL * (xc - leg.hip.X))
		lower = math.max(lower, -resid[i])
	end
	for i, leg in legs do
		step(leg.shorten, math.min(resid[i] + lower, 0.6 * (leg.a + leg.b)), 8, 1, dt)
	end
	step(self.ground.dy, gc - nominal - lower, 8, 1, dt)
	step(self.ground.pitch, math.clamp(math.atan(slopeF), -0.5, 0.5), 6, 1, dt)
	step(self.ground.roll, math.clamp(-math.atan(slopeL), -0.35, 0.35), 6, 1, dt)
end

function CreatureAnimator:_lookAround(dt: number, move: number)
	local look = self.look
	local rng = self.rng :: Random
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
			local wave = if c.kind == "back" then math.sin(self.t * 1.3 - i * 0.7) * 0.05 * i else 0
			local sag = if c.kind == "back" then 0.015 * i else 0
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
			motor.Transform = if c.kind == "back" then CFrame.Angles(la, lb, 0) else CFrame.Angles(la, 0, lb)
			prevA, prevB = a.x, b.x
		end
	end
end

-- Acciones que pide el servidor. Devuelve el peso de "comer" y los ángulos del coletazo.
function CreatureAnimator:_action(dt: number): (number, { bodyYaw: number, neckYaw: number })
	local a = self.action
	local model = self.model :: Model
	local name = model:GetAttribute("Accion") :: string?
	local id = model:GetAttribute("AccionId") :: number?
	if name ~= a.name or id ~= a.id then
		a.name, a.id, a.t = name, id, 0
	end
	a.t += dt
	step(a.eat, if name == "Comer" then 1 else 0, 0.9, 1, dt)

	local out = { bodyYaw = 0, neckYaw = 0 }
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
	self.vis1 = (self.vis1 :: CFrame):Lerp(root.CFrame, k)
	self.vis2 = (self.vis2 :: CFrame):Lerp(self.vis1, k)
	if self.isEgg then
		self:_egg(dt)
		return
	end
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
	local breath = math.sin(t * TAU * 0.28)
	local backDrop = self.drop.back.x
	local frontDrop = self.drop.front.x
	local stepRoll = math.sin(self.phase * TAU) * 0.035 * move * (1 - trot)
	local shift = math.sin(t * 0.37) * 0.025 * still
	local gp = math.sin(self.phase * TAU) -- ciclo del galope
	local bodyY = -backDrop + breath * 0.012 * L * still + gp * 0.05 * L * gallop
	-- Se inclina un poco hacia adelante al trotar; al galopar se mece adelante-atrás.
	local bodyPitch = -0.04 * trot * move + gp * 0.06 * gallop
	if self.body then
		local c0 = self.body.C0
		local visual = c0:Inverse() * root.CFrame:ToObjectSpace(self.vis2 :: CFrame) * c0
		-- Inclinación del terreno, girando alrededor del centro de las caderas a nivel del piso.
		local pivot = c0:PointToObjectSpace(self.hipCenter)
		local slope = CFrame.new(pivot) * CFrame.Angles(self.ground.pitch.x, 0, self.ground.roll.x) * CFrame.new(-pivot)
		self.body.Transform = visual
			* CFrame.new(0, bodyY + self.ground.dy.x, 0)
			* slope
			* CFrame.Angles(bodyPitch, act.bodyYaw, stepRoll + shift - yawRate * 0.04)
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
		local yaw = self.look.yaw.x * (1 - 0.7 * eat) + yawRate * 0.22 + act.neckYaw
		local pitch = self.look.pitch.x * (1 - eat) + nod - (bodyPitch + chestPitch) - self.ground.pitch.x * 0.5
		-- Comer: cabeza al pasto, mastica y cada tanto tira para arrancar.
		local tug = math.max(0, math.sin(t * TAU / 1.7)) ^ 6
		pitch += eat * (-1.25 + math.sin(t * 9) * 0.05 + tug * 0.3)
		local weights = if n >= 3 then { 0.35, 0.25, 0.4 } elseif n == 2 then { 0.5, 0.5 } else { 1 }
		for i, motor in self.neck do
			local w = weights[i] or 0
			motor.Transform = CFrame.Angles(pitch * w, yaw * w, 0)
		end
	end

	self:_chains(dt)
end

return CreatureAnimator
