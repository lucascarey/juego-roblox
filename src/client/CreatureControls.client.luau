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
	{ "Clic der", "Cabezazo (clic corto)" },
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
local guideDesc: { TextLabel } = {}
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
	guideDesc[i] = desc
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
	jumpAt: number?, -- salto cargando: despega en este momento
	leapUntil: number?, -- salto en curso: mantener el empuje hacia adelante hasta este momento
	leapDir: Vector3?,
	rightDown: number?, -- clic derecho: cuándo se apretó (si se arrastra, es girar la cámara)
	rightPos: Vector2?,
	lookSent: Vector2,
	lookAt: number,
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
		lookSent = Vector2.zero,
		lookAt = 0,
	}
	gui.Enabled = true
	-- Cada especie tiene sus ataques: la guía muestra los de esta.
	guideDesc[4].Text = stats.primary
	guideDesc[5].Text = stats.secondary .. " (clic corto)"
	-- El salto de Roblox es instantáneo: se apaga y se hace a mano (carga con las traseras, despegue).
	hum.JumpPower = 0
	-- En el aire, menos gravedad: el arco dura más y se siente pesado (la gravedad de Roblox es ~5 veces
	-- la real y hace todo muy rápido).
	local root = ch.PrimaryPart :: BasePart
	local att = Instance.new("Attachment")
	att.Parent = root
	local lift = Instance.new("VectorForce")
	lift.Name = "GravedadSalto"
	lift.Attachment0 = att
	lift.RelativeTo = Enum.ActuatorRelativeTo.World
	lift.ApplyAtCenterOfMass = true
	lift.Enabled = false
	lift.Parent = root
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
	elseif io.KeyCode == Enum.KeyCode.Space then
		-- Salto pesado: primero carga sobre las patas de atrás y recién después despega.
		-- Por estado del Humanoid: FloorMaterial sigue viendo el piso en saltos bajos (patas largas).
		local st = s.hum:GetState()
		local onGround = st ~= Enum.HumanoidStateType.Jumping and st ~= Enum.HumanoidStateType.Freefall
		if onGround and not s.jumpAt and s.stamina >= s.stats.jumpCost then
			s.stamina -= s.stats.jumpCost
			s.jumpAt = os.clock() + 0.3
			s.model:SetAttribute("SaltoEn", os.clock()) -- la animación local arranca ya
			input:FireServer("Accion", "Saltar") -- para que los demás vean la carga
		end
	elseif io.KeyCode == Enum.KeyCode.E then
		input:FireServer("Accion", "Excavar")
		s.lockedUntil = os.clock() + 2.5 -- quieta mientras excava
	elseif io.UserInputType == Enum.UserInputType.MouseButton1 then
		input:FireServer("Accion", s.stats.primary)
	elseif io.UserInputType == Enum.UserInputType.MouseButton2 then
		-- Se decide al soltar: clic corto = cabezazo, arrastrar = girar la cámara.
		s.rightDown = os.clock()
		s.rightPos = UserInputService:GetMouseLocation()
	end
end)

UserInputService.InputEnded:Connect(function(io)
	local s = state
	if not s or io.UserInputType ~= Enum.UserInputType.MouseButton2 or not s.rightDown then
		return
	end
	local held = os.clock() - s.rightDown
	local moved = (UserInputService:GetMouseLocation() - (s.rightPos :: Vector2)).Magnitude
	s.rightDown = nil
	local busy = s.model:GetAttribute("Postura") ~= nil or os.clock() < s.lockedUntil
	if held < 0.25 and moved < 8 and not busy then
		input:FireServer("Accion", s.stats.secondary)
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
	-- Despegue del salto: arriba y hacia adelante (empuje de las traseras).
	if s.jumpAt and os.clock() >= s.jumpAt then
		s.jumpAt = nil
		hum.JumpPower = stats.jumpPower * math.sqrt(s.scale)
		-- ChangeState y no Jump = true: el script de controles de Roblox pisa Jump en cada cuadro.
		hum:ChangeState(Enum.HumanoidStateType.Jumping)
		-- Empuje hacia adelante: se mantiene durante el vuelo, porque el Humanoid frena lo horizontal
		-- (en el suelo y también en el aire si no hay tecla apretada).
		local root = s.model.PrimaryPart :: BasePart
		s.leapDir = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z).Unit
		s.leapUntil = os.clock() + 0.6
		task.delay(0.1, function()
			hum.JumpPower = 0
		end)
	end
	local leapRoot = s.model.PrimaryPart
	if s.leapUntil and leapRoot then
		local st = hum:GetState()
		local flying = st == Enum.HumanoidStateType.Jumping or st == Enum.HumanoidStateType.Freefall
		if os.clock() < s.leapUntil and (flying or os.clock() < s.leapUntil - 0.45) then
			local v = leapRoot.AssemblyLinearVelocity
			local push = stats.jumpForward * s.scale
			local along = Vector3.new(v.X, 0, v.Z):Dot(s.leapDir :: Vector3)
			if along < push then
				leapRoot.AssemblyLinearVelocity = v + (s.leapDir :: Vector3) * (push - along)
			end
		else
			s.leapUntil = nil
		end
	end
	local lift = s.model.PrimaryPart and s.model.PrimaryPart:FindFirstChild("GravedadSalto") :: VectorForce?
	if lift then
		local st = hum:GetState()
		lift.Enabled = st == Enum.HumanoidStateType.Jumping or st == Enum.HumanoidStateType.Freefall
		lift.Force =
			Vector3.new(0, (lift.Parent :: BasePart).AssemblyMass * workspace.Gravity * (1 - stats.jumpGravity), 0)
	end
	-- La cabeza mira hacia donde mira la cámara: los demás jugadores lo ven por el servidor.
	local cam = workspace.CurrentCamera
	local root = s.model.PrimaryPart
	if cam and root and os.clock() - s.lookAt > 0.15 then
		local dir = root.CFrame:VectorToObjectSpace(cam.CFrame.LookVector)
		local look = Vector2.new(math.atan2(-dir.X, -dir.Z), math.asin(math.clamp(dir.Y, -1, 1)) + 0.25)
		if (look - s.lookSent).Magnitude > 0.05 then
			s.lookSent, s.lookAt = look, os.clock()
			input:FireServer("Mirar", look)
		end
	end

	healthFill.Size = UDim2.fromScale(math.clamp(hum.Health / hum.MaxHealth, 0, 1), 1)
	staminaFill.Size = UDim2.fromScale(s.stamina / stats.stamina, 1)
	stateLabel.Text = if posture == "Durmiendo"
		then "Durmiendo: regenera vida rápido"
		elseif posture == "Acostado" then "Descansando: regenera vida"
		elseif os.clock() < s.lockedUntil then "..."
		else ""
end)
