--!strict
-- Números de juego por especie (adulto). Las crías se escalan con ageScale.

export type Stats = {
	walk: number, -- studs/s
	sprint: number,
	crouch: number?, -- velocidad agazapada (tecla C); solo las especies sigilosas. El atributo
	-- "Agazapado" queda en el modelo: la visión nocturna (futura) las marca mucho menos así.
	jumpPower: number, -- más bajo = salta menos (pesada)
	jumpGravity: number, -- fracción de la gravedad en el aire: < 1 = arco más lento y pesado
	jumpForward: number, -- empuje hacia adelante al saltar (studs/s, adulta)
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
	damageBite: number?,
	primary: string, -- ataque del clic izquierdo
	secondary: string, -- ataque del clic derecho (clic corto)
	frontAttack: string, -- el que usa la IA cuando el enemigo está adelante
	damage: { [string]: number }?, -- daño de ataques propios de la especie (Pinzazo, Empujon)
	burrow: boolean?, -- Z entierra en vez de acostarse/dormir; enterrada no recibe daño
	armor: number?, -- fracción del daño que recibe (caparazón: < 1)
	sizeRange: { number }?, -- tamaño individual al azar (cada adulto distinto)
}

local SpeciesStats: { [string]: Stats } = {
	Musgo = {
		walk = 8,
		sprint = 20,
		jumpPower = 24, -- con jumpGravity 0.55 sube ~2.6 studs (un humano ~7)
		jumpGravity = 0.55,
		jumpForward = 6,
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
		primary = "Coletazo",
		secondary = "Cabezazo",
		frontAttack = "Cabezazo",
	},
	-- Especie 2: cazadora liviana y atlética; su arma es la boca en estrella.
	Grieta = {
		walk = 8,
		sprint = 30, -- la carroñera rápida de este mundo
		crouch = 4.5,
		jumpPower = 34, -- más liviana que Musgo: salta más alto y más lejos hacia adelante
		jumpGravity = 0.6,
		jumpForward = 16,
		maxHealth = 110,
		stamina = 100,
		sprintCost = 14,
		jumpCost = 22,
		staminaRegen = 12,
		regenRest = 3,
		regenSleep = 7,
		standUpRest = 2.3,
		standUpSleep = 4.5,
		damageTail = 14,
		damageHead = 10,
		damageBite = 22,
		primary = "Mordisco",
		secondary = "Coletazo",
		frontAttack = "Mordisco",
	},
	-- Especie 3: acorazada, lenta y resistente; se entierra y queda intocable.
	Hermitano = {
		walk = 5,
		sprint = 9,
		jumpPower = 14,
		jumpGravity = 0.8,
		jumpForward = 3,
		maxHealth = 200,
		stamina = 80,
		sprintCost = 18,
		jumpCost = 30,
		staminaRegen = 10,
		regenRest = 5, -- enterrado
		regenSleep = 5,
		standUpRest = 3.4, -- desenterrarse: saca las patas una por una
		standUpSleep = 3.4,
		damageTail = 0,
		damageHead = 12,
		damage = { Pinzazo = 20, Empujon = 14 },
		primary = "Pinzazo",
		secondary = "Empujon",
		frontAttack = "Pinzazo",
		burrow = true,
		armor = 0.6, -- el caparazón aguanta rasguños y golpes
		sizeRange = { 0.5, 1.8 }, -- adultos de ~7 a ~25 studs (2 a 7 m)
	},
}

-- Las crías son más lentas y más débiles.
local function ageScale(age: number): number
	return 0.4 + 0.6 * age
end

-- Velocidad por edad: la cría al 55% de la adulta (pedido de Lucas). Aparte de ageScale para no
-- cambiar vida ni daño de las crías.
local function speedScale(age: number): number
	return 0.55 + 0.45 * age
end

-- Tamaño individual: al azar dentro del rango de la especie (1 si no tiene).
local function randomSize(species: string, rng: Random?): number
	local s = SpeciesStats[species]
	local r = s and s.sizeRange
	if not r then
		return 1
	end
	return (rng or Random.new()):NextNumber(r[1], r[2])
end

return {
	randomSize = randomSize,
	get = function(species: string): Stats?
		return SpeciesStats[species]
	end,
	ageScale = ageScale,
	speedScale = speedScale,
}
