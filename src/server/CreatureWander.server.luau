--!strict
-- Paseo simple para criaturas con el atributo Wander = true: elige destinos cerca de su origen,
-- camina, a veces trota y se detiene a mirar. Solo mueve la Root anclada; el cliente anima las patas.
-- shortcut: sin pathfinding ni colisiones con obstáculos; reemplazar por la IA real de criaturas.

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local RADIUS = 22
local TURN_RATE = 1.6 -- rad/s

type State = {
	home: Vector3,
	target: Vector3?,
	speed: number,
	cur: number,
	wait: number,
	hover: number,
	rng: Random,
}

local states: { [Model]: State } = {}
local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Include
params.FilterDescendantsInstances = { workspace.Terrain }

local function groundAt(p: Vector3): number?
	local hit = workspace:Raycast(p + Vector3.new(0, 60, 0), Vector3.new(0, -200, 0), params)
	return if hit then hit.Position.Y else nil
end

local function track(model: Instance)
	if not model:IsA("Model") or not model:GetAttribute("Wander") or not model.PrimaryPart then
		return
	end
	local pos = model.PrimaryPart.Position
	states[model] = {
		home = pos,
		speed = 0,
		cur = 0,
		wait = 1,
		hover = pos.Y - (groundAt(pos) or pos.Y),
		rng = Random.new(),
	}
end

CollectionService:GetInstanceAddedSignal("Creature"):Connect(track)
for _, m in CollectionService:GetTagged("Creature") do
	track(m)
end

RunService.Heartbeat:Connect(function(dt)
	for model, s in states do
		local root = model.PrimaryPart
		if not root or not model.Parent then
			states[model] = nil
			continue
		end
		local cf = root.CFrame
		if not s.target then
			s.wait -= dt
			s.cur = math.max(0, s.cur - 6 * dt)
			if s.wait <= 0 then
				-- Paso (55%), trote (25%) o sprint (20%); el sprint va más lejos.
				local roll = s.rng:NextNumber()
				local a = s.rng:NextNumber(0, 2 * math.pi)
				local r = if roll > 0.8 then s.rng:NextNumber(25, 40) else s.rng:NextNumber(6, RADIUS)
				s.target = s.home + Vector3.new(math.cos(a) * r, 0, math.sin(a) * r)
				model:SetAttribute("Accion", nil)
				-- La mayoría camina; a veces trota.
				-- Las crías tienen patas cortas: van más lento.
				local age = model:GetAttribute("Age") :: number? or 1
				local scale = 0.4 + 0.6 * age
				s.speed = scale
					* (
						if roll > 0.8
							then s.rng:NextNumber(18, 22)
							elseif roll > 0.55 then s.rng:NextNumber(9, 12)
							else s.rng:NextNumber(3, 5)
					)
			end
		end
		local target = s.target
		if target then
			local flat = Vector3.new(target.X - cf.X, 0, target.Z - cf.Z)
			local dist = flat.Magnitude
			if dist < 1.5 then
				s.target = nil
				-- Al llegar: a veces come, a veces hace un coletazo de prueba, si no mira alrededor.
				local roll = s.rng:NextNumber()
				if roll < 0.35 then
					model:SetAttribute("Accion", "Comer")
					s.wait = s.rng:NextNumber(4, 7)
				elseif roll < 0.55 then
					model:SetAttribute("Accion", "Coletazo")
					model:SetAttribute("AccionId", (model:GetAttribute("AccionId") :: number? or 0) + 1)
					s.wait = 1.8
				else
					s.wait = s.rng:NextNumber(1.5, 4)
				end
			else
				-- Gira de a poco hacia el destino y frena en las curvas cerradas.
				local look = cf.LookVector
				local want = math.atan2(-flat.X, -flat.Z)
				local have = math.atan2(-look.X, -look.Z)
				local diff = (want - have + math.pi) % (2 * math.pi) - math.pi
				local yaw = math.clamp(diff, -TURN_RATE * dt, TURN_RATE * dt)
				local goal = s.speed * math.clamp(1 - math.abs(diff) / 1.6, 0.15, 1) * math.clamp(dist / 4, 0.3, 1)
				s.cur += math.clamp(goal - s.cur, -6 * dt, 3 * dt)
				cf = cf * CFrame.Angles(0, yaw, 0)
				cf = cf + cf.LookVector * s.cur * dt
			end
		end
		local g = groundAt(cf.Position)
		if g then
			local y = cf.Y + (g + s.hover - cf.Y) * math.min(1, 10 * dt)
			cf = CFrame.new(cf.X, y, cf.Z) * cf.Rotation
		end
		root.CFrame = cf
	end
end)
