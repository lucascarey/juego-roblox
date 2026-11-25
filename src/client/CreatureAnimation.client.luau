--!strict
-- Anima en este cliente todas las criaturas con el tag "Creature".

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CreatureAnimator = require(ReplicatedStorage.Shared.Creatures.CreatureAnimator)
local CreatureFX = require(script.Parent:WaitForChild("CreatureFX"))

local MAX_DIST = 300 -- más lejos no se nota y ahorra CPU

local animators: { [Model]: any } = {}

local function add(inst: Instance)
	if not inst:IsA("Model") or animators[inst] then
		return
	end
	-- Con streaming el modelo llega antes que sus piezas (son Atomic: llegan todas juntas).
	if not inst.PrimaryPart then
		local conn
		conn = inst:GetPropertyChangedSignal("PrimaryPart"):Connect(function()
			conn:Disconnect()
			task.defer(add, inst)
		end)
		return
	end
	local anim = CreatureAnimator.new(inst)
	anim.onEvent = CreatureFX.play -- sonidos y partículas
	animators[inst] = anim
end

CollectionService:GetInstanceAddedSignal("Creature"):Connect(function(inst)
	-- Con streaming las piezas pueden llegar después del modelo.
	task.defer(add, inst)
end)
CollectionService:GetInstanceRemovedSignal("Creature"):Connect(function(inst)
	animators[inst :: Model] = nil
end)
for _, inst in CollectionService:GetTagged("Creature") do
	add(inst)
end

-- PreSimulation: antes de resolver las articulaciones, así el cuadro dibujado ya usa la pose nueva.
RunService.PreSimulation:Connect(function(dt)
	local cam = workspace.CurrentCamera
	local camPos = if cam then cam.CFrame.Position else Vector3.zero
	for model, anim in animators do
		if not model.Parent then
			animators[model] = nil
		elseif (model:GetPivot().Position - camPos).Magnitude < MAX_DIST then
			anim:update(dt)
		end
	end
end)
