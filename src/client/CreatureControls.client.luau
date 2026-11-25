--!strict
-- Controles cuando el jugador es una criatura: sprint con stamina, salto que gasta stamina,
-- excavar, acostarse/dormir, ataques; más el HUD (vida, stamina, estado) y la guía de controles
-- plegable. La física y el movimiento son los del Humanoid de Roblox.
-- shortcut: la stamina y la velocidad viven en el cliente (zona de pruebas); pasarlas al servidor
-- antes de abrir el juego a otros jugadores.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local SpeciesStats = require(ReplicatedStorage.Shared.Creatures.SpeciesStats)
local input = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CriaturaInput") :: RemoteEvent

local player = Players.LocalPlayer

-- ------------------------------------------------------------------------------------------
-- HUD

local COLORS = {
	panel = Color3.fromRGB(24, 26, 30),
	text = Color3.fromRGB(236, 236, 240),
	dim = Color3.fromRGB(160, 164, 172),
	key = Color3.fromRGB(58, 62, 72),
	health = Color3.fromRGB(226, 84, 104),
	stamina = Color3.fromRGB(236, 196, 72),
}

local gui = Instance.new("ScreenGui")
gui.Name = "CriaturaHUD"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = false
gui.Enabled = false
gui.Parent = player:WaitForChild("PlayerGui")

local function corner(parent: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = parent
end

local function label(parent: Instance, text: string, size: number, color: Color3): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = Enum.Font.GothamMedium
	l.TextSize = size
	l.TextColor3 = color
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Text = text
	l.Parent = parent
	return l
end

-- Barras abajo a la izquierda.
local bars = Instance.new("Frame")
bars.Name = "Barras"
bars.AnchorPoint = Vector2.new(0, 1)
bars.Position = UDim2.new(0, 16, 1, -16)
bars.Size = UDim2.fromOffset(240, 74)
bars.BackgroundColor3 = COLORS.panel
bars.BackgroundTransparency = 0.25
bars.Parent = gui
corner(bars, 10)

local function bar(y: number, name: string, color: Color3): (Frame, TextLabel)
	local l = label(bars, name, 13, COLORS.dim)
	l.Position = UDim2.fromOffset(12, y)
	l.Size = UDim2.fromOffset(70, 16)
	local back = Instance.new("Frame")
	back.Position = UDim2.fromOffset(76, y + 3)
	back.Size = UDim2.fromOffset(150, 10)
	back.BackgroundColor3 = COLORS.key
	back.Parent = bars
	corner(back, 5)
	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = color
	fill.Parent = back
	corner(fill, 5)
	return fill, l
end
local healthFill = bar(10, "Vida", COLORS.health)
local staminaFill = bar(30, "Stamina", COLORS.stamina)
local stateLabel = label(bars, "", 13, COLORS.text)
stateLabel.Position = UDim2.fromOffset(12, 50)
stateLabel.Size = UDim2.fromOffset(216, 16)

-- Guía de controles a la derecha, plegable con el botón o con H.
local GUIDE = {
	{ "WASD", "Moverse" },
	{ "Shift", "Sprint (gasta stamina)" },
	{ "Espacio", "Saltar / levantarse" },
	{ "Clic izq", "Coletazo" },
	{ "Clic der", "Cabezazo" },
	{ "E", "Excavar" },
	{ "Z", "Acostarse (regenera vida)" },
	{ "Z otra vez", "Dormir (regenera más)" },
	{ "Moverse", "Levantarse" },
	{ "H", "Mostrar / ocultar esta guía" },
}

local guide = Instance.new("Frame")
guide.Name = "Guia"
guide.AnchorPoint = Vector2.new(1, 0.5)
guide.Position = UDim2.new(1, -16, 0.5, 0)
guide.Size = UDim2.fromOffset(300, 44 + #GUIDE * 24 + 40)
guide.BackgroundColor3 = COLORS.panel
guide.BackgroundTransparency = 0.2
guide.Parent = gui
corner(guide, 10)
local title = label(guide, "Controles", 16, COLORS.text)
title.Font = Enum.Font.GothamBold
title.Position = UDim2.fromOffset(14, 10)
title.Size = UDim2.fromOffset(200, 22)
for i, row in GUIDE do
	local y = 40 + (i - 1) * 24
	local key = Instance.new("TextLabel")
	key.Position = UDim2.fromOffset(14, y)
	key.Size = UDim2.fromOffset(78, 20)
	key.BackgroundColor3 = COLORS.key
	key.Font = Enum.Font.GothamBold
	key.TextSize = 12
	key.TextColor3 = COLORS.text
	key.Text = row[1]
	key.Parent = guide
	corner(key, 4)
	local desc = label(guide, row[2], 13, COLORS.dim)
	desc.Position = UDim2.fromOffset(100, y)
	desc.Size = UDim2.fromOffset(190, 20)
	desc.TextWrapped = true
end
local humanBtn = Instance.new("TextButton")
humanBtn.AnchorPoint = Vector2.new(0, 1)
humanBtn.Position = UDim2.new(0, 14, 1, -10)
humanBtn.Size = UDim2.new(1, -28, 0, 26)
humanBtn.BackgroundColor3 = COLORS.key
humanBtn.Font = Enum.Font.GothamMedium
humanBtn.TextSize = 13
humanBtn.TextColor3 = COLORS.text
humanBtn.Text = "Volver a humano"
humanBtn.Parent = guide
corner(humanBtn, 6)

local toggle = Instance.new("TextButton")
toggle.Name = "MostrarGuia"
toggle.AnchorPoint = Vector2.new(1, 0)
toggle.Position = UDim2.new(1, -16, 0, 16)
toggle.Size = UDim2.fromOffset(120, 30)
toggle.BackgroundColor3 = COLORS.panel
toggle.BackgroundTransparency = 0.2
toggle.Font = Enum.Font.GothamMedium
toggle.TextSize = 13
toggle.TextColor3 = COLORS.text
toggle.Text = "Controles (H)"
toggle.Parent = gui
corner(toggle, 8)

local function setGuide(open: boolean)
	guide.Visible = open
	toggle.Text = if open then "Ocultar (H)" else "Controles (H)"
end
setGuide(true)
toggle.Activated:Connect(function()
	setGuide(not guide.Visible)
end)
humanBtn.Activated:Connect(function()
	input:FireServer("Humano")
end)

-- ------------------------------------------------------------------------------------------
-- Estado del personaje criatura

type State = {
	model: Model,
	hum: Humanoid,
	stats: SpeciesStats.Stats,
	scale: number,
	stamina: number,
	lockedUntil: number, -- levantándose: no se puede mover
}
local state: State? = nil

local function onCharacter(ch: Model)
	state = nil
	local species = ch:GetAttribute("Species") :: string?
	local stats = species and SpeciesStats.get(species)
	local hum = ch:WaitForChild("Humanoid", 5) :: Humanoid?
	if not stats or not hum then
		gui.Enabled = false
		return
	end
	local scale = SpeciesStats.ageScale(ch:GetAttribute("Age") :: number? or 1)
	state = {
		model = ch,
		hum = hum,
		stats = stats,
		scale = scale,
		stamina = stats.stamina,
		lockedUntil = 0,
	}
	gui.Enabled = true
	hum.StateChanged:Connect(function(_, new)
		local s = state
		if s and s.hum == hum and new == Enum.HumanoidStateType.Jumping then
			s.stamina = math.max(0, s.stamina - s.stats.jumpCost)
		end
	end)
end
player.CharacterAdded:Connect(onCharacter)
if player.Character then
	task.spawn(onCharacter, player.Character)
end

local function standUp(s: State)
	local posture = s.model:GetAttribute("Postura")
	if not posture or os.clock() < s.lockedUntil then
		return -- ya se está levantando (el servidor todavía no confirmó)
	end
	input:FireServer("Postura", nil)
	s.lockedUntil = os.clock() + (if posture == "Durmiendo" then s.stats.standUpSleep else s.stats.standUpRest)
end

UserInputService.InputBegan:Connect(function(io, processed)
	if io.KeyCode == Enum.KeyCode.H and not processed then
		setGuide(not guide.Visible)
		return
	end
	local s = state
	if not s or processed then
		return
	end
	local posture = s.model:GetAttribute("Postura")
	local busy = posture ~= nil or os.clock() < s.lockedUntil
	if io.KeyCode == Enum.KeyCode.Z then
		if posture == nil and os.clock() >= s.lockedUntil then
			input:FireServer("Postura", "Acostado")
		elseif posture == "Acostado" then
			input:FireServer("Postura", "Durmiendo")
		end
	elseif io.KeyCode == Enum.KeyCode.Space and posture then
		standUp(s)
	elseif busy then
		return
	elseif io.KeyCode == Enum.KeyCode.E then
		input:FireServer("Accion", "Excavar")
		s.lockedUntil = os.clock() + 2.5 -- quieta mientras excava
	elseif io.UserInputType == Enum.UserInputType.MouseButton1 then
		input:FireServer("Accion", "Coletazo")
	elseif io.UserInputType == Enum.UserInputType.MouseButton2 then
		input:FireServer("Accion", "Cabezazo")
	end
end)

RunService.RenderStepped:Connect(function(dt)
	local s = state
	if not s or not s.model.Parent then
		return
	end
	local hum, stats = s.hum, s.stats
	local posture = s.model:GetAttribute("Postura")
	local moving = hum.MoveDirection.Magnitude > 0.1
	-- Moverse estando acostada = levantarse.
	if posture and moving then
		standUp(s)
	end
	local locked = posture ~= nil or os.clock() < s.lockedUntil
	local sprinting = not locked and moving and s.stamina > 0 and UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
	if sprinting then
		s.stamina = math.max(0, s.stamina - stats.sprintCost * dt)
	else
		local regen = stats.staminaRegen * (if posture then 2 else 1)
		s.stamina = math.min(stats.stamina, s.stamina + regen * dt)
	end
	hum.WalkSpeed = if locked then 0 else (if sprinting then stats.sprint else stats.walk) * s.scale
	hum.JumpPower = if locked or s.stamina < stats.jumpCost then 0 else stats.jumpPower * math.sqrt(s.scale)

	healthFill.Size = UDim2.fromScale(math.clamp(hum.Health / hum.MaxHealth, 0, 1), 1)
	staminaFill.Size = UDim2.fromScale(s.stamina / stats.stamina, 1)
	stateLabel.Text = if posture == "Durmiendo"
		then "Durmiendo: regenera vida rápido"
		elseif posture == "Acostado" then "Descansando: regenera vida"
		elseif os.clock() < s.lockedUntil then "..."
		else ""
end)
