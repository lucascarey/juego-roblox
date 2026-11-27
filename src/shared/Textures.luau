--!strict
-- Texturas pixeladas en escala de grises (se tiñen con Texture.Color3). Generadas con tools/gen_textures.py.

return {
	Piel = "rbxassetid://79634112914167",
	Piedra = "rbxassetid://81596402758680",
	-- Atlas de cada especie (tools/creatures.py).
	Atlas = {
		Cuadrupedo = "rbxassetid://100673216757102",
		Musgo = "rbxassetid://97383471487994",
		HuevoMusgo = "rbxassetid://86779088667442",
		Grieta = "rbxassetid://108632216192330",
		HuevoGrieta = "rbxassetid://105701807455976",
		Hermitano = "rbxassetid://105297426329925",
		HuevoHermitano = "rbxassetid://75417647028365",
	},
	-- 16 px por tile; 4 studs por tile = 4 px por stud, la misma escala en todas las piezas.
	STUDS_PER_TILE = 4,
}
