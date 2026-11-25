--!strict
-- Jugar como criatura (zona de pruebas): los carteles del corral convierten al jugador en la etapa
-- elegida. El personaje pasa a ser el modelo de la criatura con un Humanoid (física y controles de
-- Roblox) y la Root como HumanoidRootPart. También recibe las acciones/posturas del cliente y
-- regenera vida solo descansando.

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CreatureBuilder = require(ReplicatedStorage.Shared.Creatures.CreatureBuilder)
local Species = require(ReplicatedStorage.Shared.Creatures.Species)
local SpeciesStats = require(ReplicatedStorage.Shared.Creatures.SpeciesStats)
local CreatureCombat = require(script.Parent.CreatureCombat)

local remotes = ReplicatedStorage:FindFirstChild("Remotes") or Instance.new("Folder")
remotes.Name = "Remotes"
remotes.Parent = ReplicatedStorage
local input = Instance.new("RemoteEvent")
input.Name = "CriaturaInput"
input.Parent = remotes

local ACTIONS = { Excavar = 2.5 } -- las de ataque las maneja CreatureCombat
local busyUntil: { [Player]: number } = {}

local function becomeCreature(player: Player, speciesName: string, age: number, spawnAt: CFrame)
	local def = (Species :: any)[speciesName]
	local stats = SpeciesStats.get(speciesName)
	if not def or not stats then
		return
	end
	-- Apoyar en el suelo real: si aparece adentro del terreno, se cae a través de él.
	local hit = workspace:Raycast(spawnAt.Position + Vector3.new(0, 30, 0), Vector3.new(0, -80, 0))
	if hit then
		spawnAt = spawnAt.Rotation + Vector3.new(spawnAt.X, hit.Position.Y + 0.1, spawnAt.Z)
	end
	local model = CreatureBuilder.build(def, spawnAt, { age = age })
	model.Name = player.Name
	local root = model.PrimaryPart :: BasePart
	local rear = model:FindFirstChild("Rear") :: BasePart
	local chest = model:FindFirstChild("Chest") :: BasePart
	-- La Root pasa a ser la caja de colisión: ocupa la huella del cuerpo, cerca del piso.
	local hover = root.Position.Y - spawnAt.Position.Y
	local boxY = math.max(0.4, hover)
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(rear.Size.X * 0.85, boxY, (rear.Size.Z + chest.Size.Z) * 0.85)
	root.Anchored = false
	root.CanCollide = true
	root.Massless = false

	local hum = Instance.new("Humanoid")
	hum.RequiresNeck = false
	hum.BreakJointsOnDeath = false
	hum.HipHeight = hover - boxY / 2
	local scale = SpeciesStats.ageScale(age)
	hum.WalkSpeed = stats.walk * scale
	hum.UseJumpPower = true
	hum.JumpPower = stats.jumpPower * math.sqrt(scale)
	hum.MaxHealth = stats.maxHealth * scale
	hum.Health = hum.MaxHealth
	hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	hum.Parent = model
	model:SetAttribute("Jugador", player.UserId)

	local old = player.Character
	player.Character = model
	model.Parent = workspace
	if old then
		old:Destroy()
	end
end

ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, player: Player)
	local pad = prompt.Parent
	if not pad or not pad:IsA("BasePart") then
		return
	end
	if pad:GetAttribute("Humano") then
		player:LoadCharacter()
		return
	end
	local speciesName = pad:GetAttribute("Especie") :: string?
	local age = pad:GetAttribute("Edad") :: number?
	local spawnAt = pad:GetAttribute("Aparece") :: CFrame?
	if speciesName and age and spawnAt then
		becomeCreature(player, speciesName, age, spawnAt)
	end
end)

local function myCreature(player: Player): Model?
	local ch = player.Character
	if ch and ch:GetAttribute("Species") and ch:GetAttribute("Jugador") == player.UserId then
		return ch
	end
	return nil
end

input.OnServerEvent:Connect(function(player: Player, kind: unknown, value: unknown)
	local model = myCreature(player)
	if not model then
		if kind == "Humano" then
			player:LoadCharacter()
		end
		return
	end
	if kind == "Humano" then
		player:LoadCharacter()
	elseif kind == "Postura" then
		-- Solo valores conocidos; dormir solo desde acostada.
		local current = model:GetAttribute("Postura")
		if value == nil then
			model:SetAttribute("Postura", nil)
		elseif value == "Acostado" and current == nil then
			model:SetAttribute("Postura", "Acostado")
			model:SetAttribute("Accion", nil)
		elseif value == "Durmiendo" and current == "Acostado" then
			model:SetAttribute("Postura", "Durmiendo")
		end
	elseif kind == "Accion" and type(value) == "string" then
		if model:GetAttribute("Postura") or os.clock() < (busyUntil[player] or 0) then
			return
		end
		local dur = CreatureCombat.attack(model, value, player.Name) or ACTIONS[value]
		if not dur then
			return
		end
		if ACTIONS[value] then
			model:SetAttribute("Accion", value)
			model:SetAttribute("AccionId", (model:GetAttribute("AccionId") :: number? or 0) + 1)
			local id = model:GetAttribute("AccionId")
			task.delay(dur, function()
				if model:GetAttribute("AccionId") == id then
					model:SetAttribute("Accion", nil)
				end
			end)
		end
		busyUntil[player] = os.clock() + dur
	end
end)

Players.PlayerRemoving:Connect(function(p)
	busyUntil[p] = nil
end)

-- La vida solo se recupera descansando (más rápido durmiendo).
RunService.Heartbeat:Connect(function(dt)
	for _, p in Players:GetPlayers() do
		local model = myCreature(p)
		local hum = model and model:FindFirstChildOfClass("Humanoid")
		if model and hum and hum.Health > 0 then
			local stats = SpeciesStats.get(model:GetAttribute("Species") :: string)
			local posture = model:GetAttribute("Postura")
			if stats and posture then
				local rate = if posture == "Durmiendo" then stats.regenSleep else stats.regenRest
				hum.Health = math.min(hum.MaxHealth, hum.Health + rate * dt)
			end
		end
	end
end)
