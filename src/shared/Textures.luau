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
		Grieta = "rbxassetid://90509651214286",
		HuevoGrieta = "rbxassetid://90363539029359",
	},
	-- 16 px por tile; 4 studs por tile = 4 px por stud, la misma escala en todas las piezas.
	STUDS_PER_TILE = 4,
}
