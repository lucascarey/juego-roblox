--!strict
-- Números de juego por especie (adulto). Las crías se escalan con ageScale.

export type Stats = {
	walk: number, -- studs/s
	sprint: number,
	jumpPower: number, -- más bajo = salta menos (pesada)
	jumpGravity: number, -- fracción de la gravedad en el aire: < 1 = arco más lento y pesado
	maxHealth: number,
	stamina: number,
	sprintCost: number, -- por segundo
	jumpCost: number,
	staminaRegen: number, -- por segundo, de pie sin correr
	regenRest: number, -- vida por segundo acostada
	regenSleep: number, -- vida por segundo durmiendo
	standUpRest: number, -- segundos para levantarse estando acostada
	standUpSleep: number, -- ...estando dormida (más lento)
	damageTail: number,
	damageHead: number,
}

local SpeciesStats: { [string]: Stats } = {
	Musgo = {
		walk = 8,
		sprint = 20,
		jumpPower = 24, -- con jumpGravity 0.55 sube ~2.6 studs (un humano ~7)
		jumpGravity = 0.55,
		maxHealth = 120,
		stamina = 100,
		sprintCost = 16,
		jumpCost = 25,
		staminaRegen = 14,
		regenRest = 3,
		regenSleep = 7,
		standUpRest = 2,
		standUpSleep = 4,
		damageTail = 18,
		damageHead = 10,
	},
}

-- Las crías son más lentas y más débiles.
local function ageScale(age: number): number
	return 0.4 + 0.6 * age
end

return {
	get = function(species: string): Stats?
		return SpeciesStats[species]
	end,
	ageScale = ageScale,
}
