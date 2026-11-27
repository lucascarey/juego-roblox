--!nonstrict
-- Animación procedural de las especies con patas de cangrejo (Hermitaño): 6 patas de 3 falanges
-- (Leg<n>A/B/C + L/R) y 2 pinzas (ClawA, ClawB, ClawHand, ClawFinger + L/R). Corre en el cliente
-- igual que CreatureAnimator (misma interfaz: new, update, onEvent).
--   - Marcha en trípodes alternados (L1-R2-L3 / R1-L2-R3), como los cangrejos e insectos reales: un
--     trípode apoya mientras el otro da el paso, así nunca pierde apoyo y se mueve suave.
--   - Cada pie queda clavado en el mundo hasta que se aleja de su lugar de reposo; entonces su
--     trípode da un paso adelantado según la velocidad (no patina). Más grande = pasos más largos y
--     lentos (pedido de Lucas).
--   - IK por pata: la rodilla arriba (de cangrejo), la tercera falange vertical hacia el pie.
--   - Postura "Enterrado" (Z): mete rápido patas y pinzas en la tierra rascando y se hunde hasta que
--     solo queda el caparazón. Al desenterrarse saca las patas una por una, despacio, y se levanta.
--   - Flagelos de la boca y mechones de pasto: se mecen siempre, suave.
--   - Acciones (atributo "Accion"): Comer (agarra con las pinzas y lleva a la boca), Excavar, Pinzazo
--     y Empujon.

local CollectionService = game:GetService("CollectionService")

local CrabAnimator = {}
CrabAnimator.__index = CrabAnimator

local TAU = 2 * math.pi
local UP = Vector3.yAxis

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
local function refreshFilter()
	rayParams.FilterDescendantsInstances = CollectionService:GetTagged("Creature")
end
CollectionService:GetInstanceAddedSignal("Creature"):Connect(refreshFilter)

local function newSpring()
	return { x = 0, v = 0 }
end
local function step(s, target, freq, damp, dt)
	local w = TAU * freq
	local n = math.ceil(w * dt / 0.5)
	local h = dt / n
	for _ = 1, n do
		s.v += (w * w * (target - s.x) - 2 * damp * w * s.v) * h
		s.x += s.v * h
	end
end
local function smooth(k)
	k = math.clamp(k, 0, 1)
	return k * k * (3 - 2 * k)
end
local function lerp(a, b, t)
	return a + (b - a) * t
end

-- Giro mínimo que lleva el eje -Y (dirección de reposo de cada falange) a la dirección d.
local DOWN = Vector3.new(0, -1, 0)
local function aimFrom(d: Vector3): CFrame
	d = d.Unit
	local axis = DOWN:Cross(d)
	if axis.Magnitude < 1e-5 then
		return if d.Y < 0 then CFrame.identity else CFrame.Angles(math.pi, 0, 0)
	end
	return CFrame.fromAxisAngle(axis.Unit, math.acos(math.clamp(-d.Y, -1, 1)))
end

-- Apunta un motor (falange) hacia worldDir dado el CFrame de su articulación en el mundo.
-- Devuelve el CFrame de la pieza resultante.
local function aim(motor: Motor6D, joint: CFrame, worldDir: Vector3): CFrame
	local t = aimFrom(joint.Rotation:VectorToObjectSpace(worldDir))
	motor.Transform = t
	return joint * t * motor.C1:Inverse()
end

-- IK de dos tramos con el codo hacia arriba: dados cadera h, objetivo T y largos a, b, devuelve la
-- posición de la rodilla.
local function kneeUp(h: Vector3, T: Vector3, a: number, b: number, up: Vector3, fallbackOut: Vector3): Vector3
	local v = T - h
	local y = v:Dot(up)
	local hor = v - up * y
	local r = hor.Magnitude
	local out = if r > 1e-3 then hor / r else fallbackOut
	local D = math.clamp(v.Magnitude, math.abs(a - b) + 0.05, a + b - 0.02)
	local phi = math.atan2(y, r)
	local alpha = phi + math.acos(math.clamp((a * a + D * D - b * b) / (2 * a * D), -1, 1))
	return h + out * (a * math.cos(alpha)) + up * (a * math.sin(alpha))
end

local function motorsByName(model: Model)
	local out = {}
	for _, d in model:GetDescendants() do
		if d:IsA("Motor6D") then
			out[d.Name] = d
		end
	end
	return out
end

function CrabAnimator.is(model: Model): boolean
	return model:FindFirstChild("Leg1AL", true) ~= nil
end

function CrabAnimator.new(model: Model)
	refreshFilter()
	local root = model.PrimaryPart :: BasePart
	local m = motorsByName(model)
	local self = setmetatable({}, CrabAnimator)
	self.model, self.root, self.m = model, root, m
	for _, motor in m do
		if motor.Part0 == root then
			self.body = motor
		end
	end

	-- Pose de reposo (espacio de la Root) armada desde las articulaciones.
	local rest = { [root] = CFrame.identity }
	local pending = {}
	for _, motor in m do
		table.insert(pending, motor)
	end
	while #pending > 0 do
		local progressed = false
		for i = #pending, 1, -1 do
			local motor = pending[i]
			local p0 = rest[motor.Part0]
			if p0 then
				rest[motor.Part1] = p0 * motor.C0 * motor.C1:Inverse()
				table.remove(pending, i)
				progressed = true
			end
		end
		if not progressed then
			break
		end
	end
	self.rest = rest
	local bodyPart = self.body.Part1
	self.bodyRest = rest[bodyPart]

	local function tipOf(part: BasePart): Vector3
		return (rest[part] * CFrame.new(0, -part.Size.Y / 2, 0)).Position
	end
	local function jointPos(motor: Motor6D): Vector3
		return (rest[motor.Part0] * motor.C0).Position
	end

	-- Patas. Piso en reposo = la punta más baja.
	local lowest = math.huge
	local legs = {}
	for n = 1, 4 do
		for _, side in { "L", "R" } do
			local A, B, C = m["Leg" .. n .. "A" .. side], m["Leg" .. n .. "B" .. side], m["Leg" .. n .. "C" .. side]
			if A and B and C then
				local hip, knee, ankle, tip = jointPos(A), jointPos(B), jointPos(C), tipOf(C.Part1)
				lowest = math.min(lowest, tip.Y)
				table.insert(legs, {
					n = n,
					left = side == "L",
					A = A,
					B = B,
					C = C,
					a = (knee - hip).Magnitude,
					b = (ankle - knee).Magnitude,
					c = (tip - ankle).Magnitude,
					home = tip, -- en el espacio de la Root (Y se corrige abajo)
					out = Vector3.new(tip.X - hip.X, 0, tip.Z - hip.Z).Unit,
					foot = nil, -- dónde está el pie en el mundo
					from = nil,
					to = nil,
					t = 1, -- progreso del paso (1 = apoyado)
					tuck = 0,
				})
			end
		end
	end
	self.groundOffset = -lowest
	local span = 0
	for _, leg in legs do
		leg.home = Vector3.new(leg.home.X, lowest, leg.home.Z)
		span = math.max(span, math.abs(leg.home.X) * 2)
		-- Trípodes: L1-R2-L3 y R1-L2-R3.
		leg.group = if (leg.n % 2 == 1) == leg.left then 1 else 2
	end
	self.legs = legs
	self.span = span
	self.scaleK = span / 14 -- 1 = adulto de tamaño 1
	self.legLen = span * 0.25

	-- Pinzas.
	local claws = {}
	for _, side in { "L", "R" } do
		local A, B, H, F = m["ClawA" .. side], m["ClawB" .. side], m["ClawHand" .. side], m["ClawFinger" .. side]
		if A and B and H then
			local shoulder, elbow, wrist, tip = jointPos(A), jointPos(B), jointPos(H), tipOf(H.Part1)
			-- Todo en el espacio del cuerpo (Rear), que es el que se inclina.
			local inv = self.bodyRest:Inverse()
			table.insert(claws, {
				left = side == "L",
				A = A,
				B = B,
				H = H,
				F = F,
				a = (elbow - shoulder).Magnitude,
				b = (wrist - elbow).Magnitude,
				wrist = inv * wrist,
				tip = inv * tip,
				out = (inv.Rotation * (wrist - shoulder)) * Vector3.new(1, 0, 1),
				tuck = 0,
			})
		end
	end
	self.claws = claws

	-- Mechones de pasto y flagelos.
	local grass = {}
	for i = 1, 12 do
		local chain = {}
		for k = 1, 4 do
			local g = m["Grass" .. i .. "_" .. k]
			if g then
				table.insert(chain, g)
			end
		end
		if #chain > 0 then
			table.insert(grass, chain)
		end
	end
	self.grass = grass
	self.flags = {}
	for _, side in { "L", "R" } do
		local chain = {}
		for k = 1, 3 do
			local f = m["Flag" .. k .. side]
			if f then
				table.insert(chain, f)
			end
		end
		table.insert(self.flags, { chain = chain, left = side == "L" })
	end
	self.mouth = { m.MouthL, m.MouthR }

	-- Hasta dónde se hunde al enterrarse: el borde de abajo de la falda del caparazón queda bajo tierra.
	local shell = m.Shell1 and m.Shell1.Part1
	local skirtBottom = if shell then (rest[shell] * CFrame.new(0, -shell.Size.Y / 2, 0)).Position.Y else 0
	self.sinkDepth = (skirtBottom - lowest) + 0.5 * self.scaleK

	self.vis1, self.vis2, self.prevCF = root.CFrame, root.CFrame, root.CFrame
	self.vel = Vector3.zero
	self.yawRate = 0
	self.t = math.random() * 100
	self.rng = Random.new(model:GetAttribute("Seed") or math.random(1, 1e6))
	self.activeGroup = 1
	self.lastLand = { 0, 0 }
	self.ground = { dy = newSpring(), pitch = newSpring(), roll = newSpring() }
	self.sink = newSpring()
	self.bury = 0 -- 0 de pie, 1 enterrado (sigue al atributo)
	self.unburyT = nil
	self.bob = newSpring()
	self.act = { name = nil, id = nil, t = 0 }
	self.lunge = newSpring()
	self.air = false
	self.onEvent = nil
	return self
end

function CrabAnimator:_emit(name: string, pos: Vector3, extra)
	local cb = self.onEvent
	if cb then
		local ev = { pos = pos, size = 3.4 * self.scaleK }
		if extra then
			for k, v in extra do
				ev[k] = v
			end
		end
		cb(name, ev)
	end
end

local function groundY(p: Vector3, reach: number): number?
	local hit = workspace:Raycast(p + Vector3.new(0, reach, 0), Vector3.new(0, -3 * reach, 0), rayParams)
	return hit and hit.Position.Y
end

-- Enterrado: atributo Postura = "Enterrado". Bajar: rápido; subir: pata por pata.
function CrabAnimator:_burrow(dt: number)
	local buried = self.model:GetAttribute("Postura") == "Enterrado"
	local legs, claws = self.legs, self.claws
	local limbs = {}
	for _, c in claws do
		table.insert(limbs, c)
	end
	-- Orden al salir: pinzas, después adelante hacia atrás alternando lados.
	table.sort(legs, function(x, y)
		if x.n ~= y.n then
			return x.n < y.n
		end
		return x.left and not y.left
	end)
	for _, l in legs do
		table.insert(limbs, l)
	end
	if buried then
		self.unburyT = nil
		for _, l in limbs do
			l.tuck = math.min(1, l.tuck + dt / 0.35)
		end
		step(self.sink, if limbs[#limbs].tuck > 0.5 then self.sinkDepth else 0, 1.1, 1, dt)
	else
		if self.bury > 0.01 and not self.unburyT then
			self.unburyT = 0
		end
		if self.unburyT then
			self.unburyT += dt
			local T = self.unburyT
			local per = 0.32
			for i, l in limbs do
				local k = (T - (i - 1) * per) / 0.45
				if k > 0 and l.tuck > 0 then
					if l.tuck >= 1 and l.foot then
						self:_emit("Rascada", l.foot, { dir = UP })
					end
					l.tuck = math.max(0, 1 - smooth(k))
				end
			end
			-- El cuerpo sube cuando ya salió la mayoría de las patas.
			local outT = (#limbs - 2) * per
			step(self.sink, if T > outT then 0 else self.sinkDepth, 0.6, 1, dt)
			if T > outT + 1.2 then
				self.unburyT = nil
			end
		else
			for _, l in limbs do
				l.tuck = math.max(0, l.tuck - dt / 0.4)
			end
			step(self.sink, 0, 1, 1, dt)
		end
	end
	self.bury = math.clamp(self.sink.x / math.max(self.sinkDepth, 0.01), 0, 1)
	-- Rascando la tierra mientras se mete.
	if buried and self.sink.x < self.sinkDepth * 0.9 then
		self.digTick = (self.digTick or 0) - dt
		if self.digTick <= 0 then
			self.digTick = 0.12
			local l = legs[self.rng:NextInteger(1, #legs)]
			if l.foot then
				self:_emit(
					"Rascada",
					l.foot,
					{ dir = (l.foot - (self.vis2 :: CFrame).Position) * Vector3.new(1, 0, 1) }
				)
			end
		end
	end
end

function CrabAnimator:update(dt: number)
	dt = math.clamp(dt, 1 / 240, 1 / 20)
	self.t += dt
	local t = self.t
	local root = self.root
	local k = 1 - math.exp(-dt * 8)
	if (root.Position - self.vis2.Position).Magnitude > math.max(self.span * 1.5, 20) then
		self.vis1, self.vis2, self.prevCF = root.CFrame, root.CFrame, root.CFrame
		for _, leg in self.legs do
			leg.foot = nil
		end
	end
	if root.Anchored then
		self.vis1 = self.vis1:Lerp(root.CFrame, k)
		self.vis2 = self.vis2:Lerp(self.vis1, k)
	else
		self.vis1, self.vis2 = root.CFrame, root.CFrame
	end
	local cf: CFrame = self.vis2
	local delta = self.prevCF:ToObjectSpace(cf)
	local vel = (cf.Position - self.prevCF.Position) / dt
	self.prevCF = cf
	local _, dyaw = delta:ToEulerAnglesYXZ()
	self.vel = self.vel:Lerp(vel * Vector3.new(1, 0, 1), 1 - math.exp(-dt * 10))
	self.yawRate = lerp(self.yawRate, dyaw / dt, 1 - math.exp(-dt * 10))
	local speed = self.vel.Magnitude
	local S = self.scaleK

	-- Acción actual.
	local model = self.model
	local actName, actId = model:GetAttribute("Accion"), model:GetAttribute("AccionId")
	if actName ~= self.act.name or actId ~= self.act.id then
		self.act = { name = actName, id = actId, t = 0, fired = false }
	end
	self.act.t += dt
	local act = self.act

	self:_burrow(dt)
	local bury = self.bury

	-- En el aire (salto o caída): lejos del suelo.
	local nominal = cf.Y - self.groundOffset
	local gy = groundY(cf.Position, self.span)
	local air = gy ~= nil and nominal - gy > 0.6 * S and not root.Anchored
	if self.air and not air then
		self:_emit("Caida", Vector3.new(cf.X, gy or nominal, cf.Z))
		self.bob.v -= 3 * S
		for _, leg in self.legs do
			leg.foot = nil
		end
	end
	self.air = air

	-- Paso: umbral y duración crecen con el tamaño (pasos largos y lentos en los grandes).
	local thresh = 0.17 * self.span
	local dur = math.clamp(0.3 * math.sqrt(S), 0.18, 0.55)
	local lift = 0.09 * self.span

	-- Lugar de reposo de cada pie ahora y su velocidad (incluye el giro en el lugar).
	local planted = { 0, 0 }
	local groupDue = { false, false }
	for _, leg in self.legs do
		local home = cf:PointToWorldSpace(leg.home)
		leg.homeVel = if leg.homePrev then (home - leg.homePrev) / dt else Vector3.zero
		leg.homePrev = home
		leg.homeW = home
		if not leg.foot then
			local y = groundY(home, self.span) or home.Y
			leg.foot = Vector3.new(home.X, y, home.Z)
			leg.t = 1
		end
		if leg.t >= 1 then
			planted[leg.group] += 1
			local off = (leg.foot - home) * Vector3.new(1, 0, 1)
			if off.Magnitude > thresh then
				groupDue[leg.group] = true
			end
			if off.Magnitude > thresh * 1.8 then
				leg.urgent = true
			end
		end
	end
	local busy = bury > 0.02 or act.name == "Comer"
	if not air and not busy then
		for g = 1, 2 do
			local other = 3 - g
			local otherDone = planted[other] == 3 and t - self.lastLand[other] > dur * 0.15
			if groupDue[g] and otherDone then
				for _, leg in self.legs do
					local off = ((leg.foot - leg.homeW) * Vector3.new(1, 0, 1)).Magnitude
					if leg.group == g and leg.t >= 1 and (off > thresh * 0.25 or leg.urgent) then
						-- Adelantado: llega delante de su lugar para pasar de largo hasta el umbral.
						local hv = leg.homeVel * Vector3.new(1, 0, 1)
						local hvm = hv.Magnitude
						local lead = if hvm > 0.05
							then hv / hvm * math.min(thresh * 0.85, hvm * dur * 2)
							else Vector3.zero
						local to = leg.homeW + hv * dur + lead
						to = Vector3.new(to.X, groundY(to, self.span) or to.Y, to.Z)
						leg.from, leg.to, leg.t = leg.foot, to, 0
						leg.urgent = false
					end
				end
			end
		end
	end
	-- Avanzar los pasos.
	for _, leg in self.legs do
		if leg.t < 1 then
			leg.t = math.min(1, leg.t + dt / dur)
			local e = smooth(leg.t)
			local p = leg.from:Lerp(leg.to, e)
			leg.foot = p + UP * (math.sin(math.pi * leg.t) * lift)
			if leg.t >= 1 then
				leg.foot = leg.to
				self.lastLand[leg.group] = t
				self.bob.v -= 0.6 * S
				if speed > 0.3 then
					self:_emit("Pisada", leg.foot, { speed = speed })
				end
			end
		elseif air then
			leg.foot = leg.homeW + UP * (0.15 * self.span)
		end
	end

	-- Cuerpo: altura y plano desde los pies apoyados (adelante/atrás, izquierda/derecha).
	local F, B, Lf, R, nF, nB, nL, nR = 0, 0, 0, 0, 0, 0, 0, 0
	for _, leg in self.legs do
		local y = if leg.t < 1 then leg.to.Y else leg.foot.Y
		if leg.n == 1 then
			F, nF = F + y, nF + 1
		elseif leg.n == 3 then
			B, nB = B + y, nB + 1
		end
		if leg.left then
			Lf, nL = Lf + y, nL + 1
		else
			R, nR = R + y, nR + 1
		end
	end
	local avg = (Lf + R) / math.max(1, nL + nR)
	local zSpan, xSpan = 0.45 * self.span, 0.8 * self.span
	local pitchT = if nF > 0 and nB > 0 then math.atan(((F / nF) - (B / nB)) / zSpan) else 0
	local rollT = if nL > 0 and nR > 0 then -math.atan(((Lf / nL) - (R / nR)) / xSpan) else 0
	local onGround = if air then 0 else 1
	step(self.ground.dy, math.clamp(avg - nominal, -0.4 * self.legLen, 0.4 * self.legLen) * onGround, 6, 1, dt)
	step(self.ground.pitch, math.clamp(pitchT, -0.4, 0.4) * onGround, 5, 1, dt)
	step(self.ground.roll, math.clamp(rollT, -0.3, 0.3) * onGround, 5, 1, dt)
	step(self.bob, 0, 3, 0.5, dt)

	-- Respiración y vaivén de cada trípode; empujón y pinzazo mueven el cuerpo.
	local breath = math.sin(t * TAU * 0.22) * 0.04 * S
	local sway = 0
	for _, leg in self.legs do
		if leg.t < 1 then
			sway += (if leg.group == 1 then 1 else -1) * math.sin(math.pi * leg.t) * 0.02
		end
	end
	local lungeT, shellPitch = 0, 0
	if act.name == "Empujon" then
		local a = act.t
		local wind = smooth(a / 0.25) * (1 - smooth((a - 0.3) / 0.1))
		local hit = smooth((a - 0.3) / 0.12) * (1 - smooth((a - 0.55) / 0.5))
		lungeT = -0.35 * wind + 1.4 * hit
		shellPitch = 0.06 * wind - 0.22 * hit
		if a >= 0.4 and not act.fired then
			act.fired = true
			self:_emit("Embestida", cf.Position + cf.LookVector * self.span * 0.45, { dir = cf.LookVector })
		end
	elseif act.name == "Pinzazo" then
		local a = act.t
		lungeT = 0.4 * smooth((a - 0.25) / 0.15) * (1 - smooth((a - 0.6) / 0.4))
	end
	step(self.lunge, lungeT * S, 5, 0.8, dt)
	local digRock = 0
	if model:GetAttribute("Postura") == "Enterrado" and self.sink.x < self.sinkDepth * 0.95 then
		digRock = math.sin(t * 22) * 0.03
	elseif self.unburyT and self.sink.x > 0.05 then
		digRock = math.sin(t * 9) * 0.015
	end
	local c0 = self.body.C0
	local visual = c0:Inverse() * root.CFrame:ToObjectSpace(cf) * c0
	local pivot = c0:PointToObjectSpace(cf:PointToObjectSpace(cf.Position)) -- centro del cuerpo a nivel del piso
	local bodyT = visual
		* CFrame.new(0, self.ground.dy.x + self.bob.x * 0.1 + breath - self.sink.x, -self.lunge.x)
		* CFrame.new(pivot)
		* CFrame.Angles(self.ground.pitch.x + shellPitch, 0, self.ground.roll.x + sway + digRock)
		* CFrame.new(-pivot)
	self.body.Transform = bodyT
	local bodyCF = root.CFrame * c0 * bodyT * self.body.C1:Inverse() -- mundo (bodyT ya lleva el desfase Root -> vis2)

	-- Patas: pie objetivo (apoyado o metido bajo el caparazón al enterrarse) -> IK.
	local up = bodyCF.UpVector
	for _, leg in self.legs do
		local foot = leg.foot
		if leg.tuck > 0 then
			-- Metida: el pie va bajo el borde del caparazón, pegado al cuerpo, rascando al entrar/salir.
			local hipW = (bodyCF * leg.A.C0).Position
			local outW = bodyCF:VectorToWorldSpace(leg.out)
			local scratch = math.sin(t * 24 + leg.n) * 0.25 * S * (1 - math.abs(2 * leg.tuck - 1))
			-- Hacia abajo, casi estirada: se clava en la tierra y la rodilla queda bajo el caparazón.
			local tucked = hipW + outW * (leg.a * 0.5 + scratch) - up * ((leg.a + leg.b) * 0.8)
			foot = foot:Lerp(tucked, smooth(leg.tuck))
		end
		local hipJ = bodyCF * leg.A.C0
		local ankleT = foot + UP * leg.c
		local fallback = bodyCF:VectorToWorldSpace(leg.out)
		local knee = kneeUp(hipJ.Position, ankleT, leg.a, leg.b, up, fallback)
		local femur = aim(leg.A, hipJ, knee - hipJ.Position)
		local kneeJ = femur * leg.B.C0
		local tibia = aim(leg.B, kneeJ, ankleT - kneeJ.Position)
		local ankleJ = tibia * leg.C.C0
		aim(leg.C, ankleJ, foot - ankleJ.Position)
	end

	-- Pinzas: objetivo de la muñeca y de la punta de la mano en el espacio del cuerpo.
	local eating = act.name == "Comer"
	for i, claw in self.claws do
		local wrist, tip = claw.wrist, claw.tip
		local fingerOpen = 0.08 + 0.05 * math.sin(t * 0.7 + i)
		local raise = math.clamp(speed / (3 * S), 0, 1) * 0.5 * S
		wrist += Vector3.new(0, raise, 0)
		tip += Vector3.new(0, raise * 1.6, -raise * 0.4)
		local sideSign = if claw.left then -1 else 1
		if eating then
			-- Turnándose: una pinza baja al piso adelante, agarra y la lleva a la boca.
			local cyc = ((t / 1.8) + (if claw.left then 0.5 else 0)) % 1
			local mouth = Vector3.new(0.4 * sideSign * S, -1.0 * S, (claw.wrist.Z + 1.0 * S))
			local ground = claw.tip + Vector3.new(-0.3 * sideSign * S, -0.3 * S, -1.2 * S)
			local reach = smooth(cyc / 0.35) * (1 - smooth((cyc - 0.45) / 0.3))
			local feed = smooth((cyc - 0.45) / 0.3) * (1 - smooth((cyc - 0.85) / 0.15))
			wrist = wrist:Lerp(claw.wrist + Vector3.new(0, 0.2 * S, -1.2 * S), reach)
			tip = tip:Lerp(ground, reach)
			wrist = wrist:Lerp(mouth + Vector3.new(0.6 * sideSign * S, 0.9 * S, -0.9 * S), feed)
			tip = tip:Lerp(mouth, feed)
			fingerOpen = if cyc < 0.35 then 0.5 elseif cyc < 0.45 then 0.5 * (1 - (cyc - 0.35) / 0.1) else 0
		elseif act.name == "Pinzazo" and not claw.left then
			local a = act.t
			local cock = smooth(a / 0.25) * (1 - smooth((a - 0.3) / 0.1))
			local strike = smooth((a - 0.3) / 0.12) * (1 - smooth((a - 0.6) / 0.4))
			wrist = wrist:Lerp(claw.wrist + Vector3.new(0.2 * S, 1.0 * S, 0.4 * S), cock)
			tip = tip:Lerp(claw.wrist + Vector3.new(0.4 * S, 1.6 * S, -0.6 * S), cock)
			wrist = wrist:Lerp(claw.wrist + Vector3.new(-0.2 * S, 0.6 * S, -2.6 * S), strike)
			tip = tip:Lerp(claw.wrist + Vector3.new(-0.5 * S, 0.5 * S, -5.2 * S), strike)
			fingerOpen = if a < 0.38 then 0.6 * smooth(a / 0.2) else 0
			if a >= 0.42 and not act.fired then
				act.fired = true
				local p = (bodyCF * CFrame.new(tip)).Position
				self:_emit("CabezaGolpe", p, { dir = bodyCF.LookVector })
			end
		elseif act.name == "Empujon" then
			-- Pinzas recogidas contra la cara para empujar con el caparazón.
			local k2 = smooth(act.t / 0.2) * (1 - smooth((act.t - 0.8) / 0.3))
			wrist = wrist:Lerp(claw.wrist + Vector3.new(-0.4 * sideSign * S, 0.4 * S, 1.0 * S), k2)
			tip = tip:Lerp(claw.wrist + Vector3.new(-0.6 * sideSign * S, -0.6 * S, 0.6 * S), k2)
		elseif act.name == "Excavar" then
			local dg = math.sin(t * 8 + i * math.pi)
			wrist += Vector3.new(0, 0.3 * S * dg, -0.3 * S)
			tip += Vector3.new(0, -0.3 * S, 0.8 * S * dg - 0.4 * S)
			if dg > 0.95 and (claw.lastDig or 0) < t - 0.3 then
				claw.lastDig = t
				self:_emit("Rascada", (bodyCF * CFrame.new(tip)).Position, { dir = -bodyCF.LookVector })
			end
		end
		if claw.tuck > 0 then
			local e = smooth(claw.tuck)
			wrist = wrist:Lerp(claw.wrist + Vector3.new(-0.3 * sideSign * S, -2.0 * S, 0.6 * S), e)
			tip = tip:Lerp(claw.wrist + Vector3.new(-0.4 * sideSign * S, -3.6 * S, 0.4 * S), e)
		end
		local shJ = bodyCF * claw.A.C0
		local wW = (bodyCF * CFrame.new(wrist)).Position
		local tW = (bodyCF * CFrame.new(tip)).Position
		local elbow = kneeUp(shJ.Position, wW, claw.a, claw.b, up, bodyCF:VectorToWorldSpace(claw.out))
		local armA = aim(claw.A, shJ, elbow - shJ.Position)
		local elbowJ = armA * claw.B.C0
		local armB = aim(claw.B, elbowJ, wW - elbowJ.Position)
		local wristJ = armB * claw.H.C0
		aim(claw.H, wristJ, tW - wristJ.Position)
		if claw.F then
			claw.F.Transform = CFrame.Angles(0, 0, -fingerOpen * (if claw.left then -1 else 1))
		end
	end

	-- Flagelos: se mecen siempre, suave; comiendo, más rápido.
	local fq = if eating then 2.2 else 1
	for i, f in self.flags do
		local s = if f.left then -1 else 1
		for j, motor in f.chain do
			local ph = t * fq + i * 1.7 + j * 0.6
			motor.Transform = CFrame.Angles(math.sin(ph * 1.6) * 0.22, 0, s * math.sin(ph * 1.05) * 0.14)
		end
	end
	for _, motor in self.mouth do
		if motor then
			motor.Transform = CFrame.Angles(if eating then math.sin(t * 10) * 0.25 else 0, 0, 0)
		end
	end
	-- Mechones: viento suave y un poco de inercia al arrancar o frenar.
	local accel = self.vel - (self.prevVel or self.vel)
	self.prevVel = self.vel
	self.grassLean = lerp(self.grassLean or 0, math.clamp(accel.Magnitude / dt * 0.01, 0, 0.3), 1 - math.exp(-dt * 4))
	for i, chain in self.grass do
		for j, motor in chain do
			local w = math.sin(t * 1.1 + i * 2.3) * 0.07 + math.sin(t * 2.7 + i) * 0.03
			motor.Transform = CFrame.Angles((w + self.grassLean) * j, 0, math.sin(t * 0.8 + i * 1.3) * 0.06 * j)
		end
	end
end

return CrabAnimator
