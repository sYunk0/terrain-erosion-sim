shader_type spatial;

uniform sampler2D height_map;
uniform vec2 height_map_size;
uniform float height_map_scale:hint_range(0.0, 1.0) = 0.005;
uniform float max_height_map_val = 200.0;
const float HEIGHT_MAP_SCALE_MULTIPLIER = 1.0;

uniform vec3 water_color:source_color;
const float MAX_WATER_VAL = 50.0;

void vertex() {
	vec4 twsh = texture(height_map,UV);
	VERTEX.y += height_map_scale * HEIGHT_MAP_SCALE_MULTIPLIER * (twsh.x + twsh.y + twsh.z - 1.0);
}

void fragment() {
	// Called for every pixel the material is visible on.
	vec4 twsh = texture(height_map,UV);

	ALBEDO = water_color;
	ALPHA = clamp(twsh.y / MAX_WATER_VAL, 0.0, 0.55);
}

//void light() {
//	// Called for every pixel for every light affecting the material.
//	// Uncomment to replace the default light processing function with this one.
//}
