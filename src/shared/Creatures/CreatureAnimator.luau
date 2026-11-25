--!strict
-- Animación procedural de criaturas de cajas (corre en el cliente: Motor6D.Transform no se replica).
-- Lee el movimiento de la Root (que mueve el servidor) y de ahí saca todo:
--   - Paso: caminata en secuencia lateral que pasa a trote (pares diagonales) con la velocidad.
--     La zancada se calcula con el largo real de la pata, así las patas de apoyo no patinan.
--   - Cuerpo: baja cuando las patas de apoyo se inclinan, rola y flexiona la columna al girar.
--   - Cuello y cabeza: compensan el cabeceo del cuerpo, adelantan los giros y miran alrededor en reposo.
--   - Cola, antenas y barba: resortes con inercia (se quedan atrás y rebotan cuando el cuerpo acelera).
--   - Reposo: respiración y cambio de peso.
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
}
type Leg = { upper: Motor6D, lower: Motor6D?, front: boolean, left: boolean }

local function newSpring(): Spring
	return { x = 0, v = 0 }
end

-- Resorte amortiguado (Euler semi-implícito), definido por frecuencia (Hz) y amortiguación (1 = crítico).
local function step(s: Spring, target: number, freq: number, damp: number, dt: number)
	local w = TAU * freq
	s.v += (w * w * (target - s.x) - 2 * damp * w * s.v) * dt
	s.x += s.v * dt
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
				table.insert(legs, {
					upper = upper,
					lower = m["Leg" .. fb .. "L" .. side],
					front = fb == "F",
					left = side == "L",
				})
				local p0 = rest[upper.Part0 :: BasePart]
				if p0 then
					hipY = math.max(hipY, (p0 * upper.C0).Position.Y)
				end
			end
		end
	end
	self.legs = legs
	self.legLen = math.max(0.5, hipY - lowest)
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

	-- Del paso a trote según la velocidad relativa al largo de pata.
	local trot = math.clamp((s / L - 1.1) / 0.9, 0, 1)
	local amp = lerp(0.26, 0.5, math.clamp(gaitSpeed / (3 * L), 0, 1))
	local duty = lerp(0.66, 0.5, trot)
	local stride = 2 * L * math.sin(amp) / duty -- avance del cuerpo por ciclo sin patinar
	local dir = if self.speed.x < -0.05 then -1 else 1
	self.phase = (self.phase + dir * gaitSpeed / stride * dt) % 1

	local move = self.move.x
	local drops = { front = 1, back = 1 }
	for _, leg in self.legs :: { Leg } do
		-- Caminata: trasera izq, delantera izq, trasera der, delantera der. Trote: diagonales juntas.
		local walkOff = (if leg.front then 0.25 else 0) + (if leg.left then 0 else 0.5)
		local trotOff = if leg.front == leg.left then 0.5 else 0
		local u = (self.phase + lerp(walkOff, trotOff, trot)) % 1
		local hip, knee = legPose(u, duty, amp)
		hip *= move
		knee *= move
		leg.upper.Transform = CFrame.Angles(hip, 0, 0)
		if leg.lower then
			-- La rodilla dobla hacia atrás en el vuelo; un poco más en las traseras.
			leg.lower.Transform = CFrame.Angles(knee * (if leg.front then 1 else 1.2), 0, 0)
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
		local rx, ry, rz = rel:ToEulerAnglesXYZ()
		local d = rel.Position
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
			step(a, prevA + sag, c.freq[i], c.damp, dt)
			step(b, prevB + wave, c.freq[i], c.damp, dt)
			a.x = math.clamp(a.x, prevA - 0.8, prevA + 0.8)
			b.x = math.clamp(b.x, prevB - 0.8, prevB + 0.8)
			local la, lb = a.x - prevA, b.x - prevB
			motor.Transform = if c.kind == "back" then CFrame.Angles(la, lb, 0) else CFrame.Angles(la, 0, lb)
			prevA, prevB = a.x, b.x
		end
	end
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
	local move, trot = self:_locomotion(dt)
	self:_lookAround(dt, move)
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
	local bodyY = -backDrop + breath * 0.012 * L * still
	local bodyPitch = -0.04 * trot * move -- se inclina un poco hacia adelante al trotar
	if self.body then
		local c0 = self.body.C0
		local visual = c0:Inverse() * root.CFrame:ToObjectSpace(self.vis2 :: CFrame) * c0
		self.body.Transform = visual
			* CFrame.new(0, bodyY, 0)
			* CFrame.Angles(bodyPitch, 0, stepRoll + shift - yawRate * 0.04)
	end
	local chestPitch = 0
	if self.spine then
		local rel = frontDrop - backDrop
		chestPitch = -math.asin(math.clamp(rel / self.bodyLen, -0.5, 0.5)) + breath * 0.01 * still
		local spineYaw = yawRate * 0.12 + math.sin(self.phase * TAU) * 0.03 * move * (1 - trot)
		self.spine.Transform = CFrame.Angles(chestPitch, spineYaw, 0)
	end

	-- Cuello y cabeza: compensan el cuerpo para que la cabeza quede estable, adelantan el giro,
	-- cabecean con el paso y miran alrededor.
	local n = #self.neck
	if n > 0 then
		local nod = math.sin(self.phase * TAU * 2) * 0.05 * move * (1 - trot * 0.5)
		local yaw = self.look.yaw.x + yawRate * 0.22
		local pitch = self.look.pitch.x + nod - (bodyPitch + chestPitch)
		local weights = if n >= 3 then { 0.35, 0.25, 0.4 } elseif n == 2 then { 0.5, 0.5 } else { 1 }
		for i, motor in self.neck do
			local w = weights[i] or 0
			motor.Transform = CFrame.Angles(pitch * w, yaw * w, 0)
		end
	end

	self:_chains(dt)
end

return CreatureAnimator
