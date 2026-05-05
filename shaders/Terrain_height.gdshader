shader_type spatial;

uniform sampler2D height_map;
uniform vec2 height_map_size;
uniform float height_map_scale:hint_range(0.0, 1.0) = 0.005;
uniform float sample_dist_multiplyer:hint_range(0.1, 5.0) = 1.0;
uniform float max_height_map_val = 200.0;
const float HEIGHT_MAP_SCALE_MULTIPLIER = 1.0;

uniform vec3 low_terrain_color:source_color;
uniform vec3 high_terrain_color:source_color;

vec3 getNormalFromHeightMap(vec2 texCoord)
{
    vec2 sampleDist = vec2(sample_dist_multiplyer) / height_map_size;

    vec2 sampleRight = texCoord + vec2(sampleDist.x,0.0);
    vec2 sampleLeft = texCoord + vec2(-sampleDist.x,0.0);
    vec2 sampleUp = texCoord + vec2(0.0, sampleDist.y);
    vec2 sampleDown = texCoord + vec2(0.0,-sampleDist.y);

    float deltaU = height_map_scale* HEIGHT_MAP_SCALE_MULTIPLIER * (texture(height_map,sampleRight).r - texture(height_map,sampleLeft).r);
    float deltaV = height_map_scale* HEIGHT_MAP_SCALE_MULTIPLIER * (texture(height_map,sampleUp).r - texture(height_map,sampleDown).r);

    return normalize( cross( vec3( 0.0 ,deltaV, 2.0*sampleDist.y) ,vec3(2.0*sampleDist.x, deltaU, 0.0)));
}

void vertex() {
	vec4 twsh = texture(height_map,UV);
	VERTEX.y += height_map_scale * HEIGHT_MAP_SCALE_MULTIPLIER * (twsh.x);
	NORMAL = getNormalFromHeightMap(UV);
	
}

void fragment() {
	// Called for every pixel the material is visible on.
	vec4 twsh = texture(height_map,UV);
	
	//ALBEDO = albedo + vec3(0.0,0.0,10.0*twsh.y);
	//ALBEDO = twsh.xyz;
	float i = (twsh.x) / (max_height_map_val);
	ALBEDO = low_terrain_color + i *(high_terrain_color - low_terrain_color);
	//if(twsh.y > 0.0)
	//{
		//ALBEDO += vec3(0.0,0.0,0.25 * twsh.y);
	//}
	ALBEDO = ALBEDO / (vec3(1.0) + ALBEDO);
}

//void light() {
//	// Called for every pixel for every light affecting the material.
//	// Uncomment to replace the default light processing function with this one.
//}
