--!strict
-- Golpes de criaturas (jugadores o IA): coletazo y cabezazo. Calcula a quién alcanza en el momento
-- del impacto de la animación y aplica daño a personajes con Humanoid; a las criaturas IA les avisa
-- con atributos (AtacadoPor / AtacadoEn) para que reaccionen.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SpeciesStats = require(ReplicatedStorage.Shared.Creatures.SpeciesStats)

local CreatureCombat = {}

-- Momento del impacto dentro de cada animación (segundos) y duración total.
CreatureCombat.TIMING = {
	Coletazo = { hit = 0.55, total = 1.5 },
	Cabezazo = { hit = 0.4, total = 1 },
}

local function sizeOf(model: Model): (number, number)
	local rear = model:FindFirstChild("Rear") :: BasePart?
	local chest = model:FindFirstChild("Chest") :: BasePart?
	local len = (if rear then rear.Size.Z else 3) + (if chest then chest.Size.Z else 3)
	local tail = 0
	for i = 1, 8 do
		local seg = model:FindFirstChild("Tail" .. i) :: BasePart?
		if seg then
			tail += seg.Size.Z
		end
	end
	return len, tail
end

-- Candidatos: personajes de jugadores y criaturas (menos el atacante y los huevos).
local function targets(attacker: Model): { Model }
	local out = {}
	for _, p in game:GetService("Players"):GetPlayers() do
		local ch = p.Character
		if ch and ch ~= attacker and ch.PrimaryPart then
			table.insert(out, ch)
		end
	end
	for _, m in CollectionService:GetTagged("Creature") do
		if m ~= attacker and m:IsA("Model") and m.PrimaryPart and m:FindFirstChild("Rear") then
			if not table.find(out, m) then
				table.insert(out, m)
			end
		end
	end
	return out
end

-- Aplica el golpe al instante (llamar en el momento del impacto). Devuelve los modelos alcanzados.
function CreatureCombat.resolve(attacker: Model, kind: string, attackerName: string): { Model }
	local root = attacker.PrimaryPart
	if not root or not attacker.Parent then
		return {}
	end
	local species = attacker:GetAttribute("Species") :: string? or ""
	local stats = SpeciesStats.get(species)
	local age = attacker:GetAttribute("Age") :: number? or 1
	local scale = SpeciesStats.ageScale(age)
	local bodyLen, tailLen = sizeOf(attacker)
	local cf = root.CFrame
	local hits = {}
	local group = attacker:GetAttribute("Grupo")
	for _, t in targets(attacker) do
		if group and t:GetAttribute("Grupo") == group then
			continue -- no pegarle a la propia familia/manada
		end
		local tp = (t.PrimaryPart :: BasePart).Position
		local rel = cf:PointToObjectSpace(tp)
		local flat = Vector3.new(rel.X, 0, rel.Z)
		local dist = flat.Magnitude
		local hit = false
		if kind == "Coletazo" then
			-- Arco detrás y a los costados, hasta el largo del cuerpo + cola.
			hit = dist < bodyLen * 0.5 + tailLen and rel.Z > -bodyLen * 0.2
		elseif kind == "Cabezazo" then
			-- Adelante, cerca.
			hit = rel.Z < 0 and dist < bodyLen * 0.9 and math.abs(rel.X) < bodyLen * 0.5
		end
		if hit then
			table.insert(hits, t)
			local hum = t:FindFirstChildOfClass("Humanoid")
			local dmg = if stats
				then (if kind == "Coletazo" then stats.damageTail else stats.damageHead) * scale
				else 10
			if hum then
				hum:TakeDamage(dmg)
			end
			t:SetAttribute("AtacadoPor", attackerName)
			t:SetAttribute("AtacadoEn", os.clock())
		end
	end
	return hits
end

-- Pone la animación (atributos) y programa el impacto. Devuelve la duración o nil si no aplica.
function CreatureCombat.attack(attacker: Model, kind: string, attackerName: string): number?
	local timing = CreatureCombat.TIMING[kind]
	if not timing then
		return nil
	end
	attacker:SetAttribute("Accion", kind)
	attacker:SetAttribute("AccionId", (attacker:GetAttribute("AccionId") :: number? or 0) + 1)
	local id = attacker:GetAttribute("AccionId")
	task.delay(timing.hit, function()
		if attacker:GetAttribute("AccionId") == id then
			CreatureCombat.resolve(attacker, kind, attackerName)
		end
	end)
	task.delay(timing.total, function()
		if attacker:GetAttribute("AccionId") == id and attacker:GetAttribute("Accion") == kind then
			attacker:SetAttribute("Accion", nil)
		end
	end)
	return timing.total
end

return CreatureCombat
