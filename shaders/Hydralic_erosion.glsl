#[compute]
#version 450

/**
 * A hydralic and thermal erosion simulator for the GPU based on the work from Balazs Jako in "Fast Hydraulic and Thermal Erosion on the GPU"
 * https://old.cescg.org/CESCG-2011/papers/TUBudapest-Jako-Balazs.pdf
 *
 */
#define LEFT x
#define RIGHT y
#define TOP z
#define BOTTOM w

#define LEFT_TOP x
#define RIGHT_TOP y
#define LEFT_BOTTOM z
#define RIGHT_BOTTOM w


#define TERRAIN previous_twsh.x
#define WATER previous_twsh.y
#define SEDIMENT previous_twsh.z
#define HARDNESS previous_twsh.w

layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;


layout(rgba32f, set=0, binding=0) readonly uniform image2D terrain_water_sediment_heights_local_harness;
layout(rgba32f, set=0, binding=1) readonly uniform image2D water_outflow_flux;
layout(rgba32f, set=0, binding=2) readonly uniform image2D thermal_erosion_buffer;
layout(rgba32f, set=0, binding=3) readonly uniform image2D thermal_erosion_buffer_diagonals;


layout(rgba32f, set=1, binding=0) writeonly uniform image2D terrain_water_sediment_heights_local_harness_write;
layout(rgba32f, set=1, binding=1) writeonly uniform image2D water_outflow_flux_write;
layout(rgba32f, set=1, binding=2) writeonly uniform image2D thermal_erosion_buffer_write;
layout(rgba32f, set=1, binding=3) writeonly uniform image2D thermal_erosion_buffer_diagonals_write;

layout(push_constant, std430) uniform Params {
	ivec2 image_size;
	int pad1; int pad2;

	float gravity;  // g
	float rain_rate;  // constant rain per step.
	float delta_t;	  // timestep amount.
	float pipe_area_length_ratio;

	float cell_distance;
	float sediment_capacity;  // K_c
	float thermal_erosion_rate; //K_t
	float soil_suspension_rate; //K_s

	float sediment_deposition_rate; // K_d
	float sediment_softening_rate; // K_h
	float maximum_erosion_depth; //K_{d max}
	float talus_angle_tangent_coefficient; // K_a

	float talus_angle_tangent_bias; // K_i
	float minimum_soil_hardness;	// R_{min} 
	float evaporation_rate;		 // K_e
	float max_evaporation_amount;
} params;

const float WATER_DAMPENING_TERRAIN_HEIGHT_COEFFICIENT = 8.0;

//this function may be called for any point not just the neighbors so I am leaving it's image load.
float sedimentAt(ivec2 texCoord)
{
	if(any(greaterThanEqual(texCoord,params.image_size)) || any(lessThan(texCoord,ivec2(0))))
	{
		return 0.0;
	}
	else
	{
		return imageLoad(terrain_water_sediment_heights_local_harness,texCoord).z;
	}
}


float limit_ramp_function(float x)
{
	return 1.0 - clamp( x / params.maximum_erosion_depth,0.0,1.0);
}

float isTalusSlope(float neighborHeight, float cellHeight, float cellHardness)
{
	cellHeight -= neighborHeight;
	return neighborHeight * float((cellHeight > 0.0) && (((cellHeight/params.cell_distance)) > ((1.0 - cellHardness) * params.talus_angle_tangent_coefficient + params.talus_angle_tangent_bias)));
}

void main()
{
	ivec2 texCoord = ivec2(gl_WorkGroupID.xy);
	vec4 previous_twsh = imageLoad(terrain_water_sediment_heights_local_harness,texCoord);
	vec4 flows = imageLoad(water_outflow_flux,texCoord);

	float cell_area = params.cell_distance*params.cell_distance;

	//Get current and neighboring values
	vec2 left_height = previous_twsh.xy;
	vec2 right_height = previous_twsh.xy;
	vec2 top_height = previous_twsh.xy;
	vec2 bottom_height = previous_twsh.xy;

	float left_neighbor_outflow = 0.0;
	float right_neighbor_outflow = 0.0;
	float top_neighbor_outflow = 0.0;
	float bottom_neighbor_outflow = 0.0;

	
	vec2 left_neighbor_erosion = vec2(0.0,TERRAIN); // x = erosion from cell, y = height of that cell, z = hardness of that cell
	vec2 right_neighbor_erosion = vec2(0.0,TERRAIN);
	vec2 top_neighbor_erosion = vec2(0.0,TERRAIN);
	vec2 bottom_neighbor_erosion = vec2(0.0,TERRAIN);
	vec2 left_top_neighbor_erosion = vec2(0.0,TERRAIN);
	vec2 left_bottom_neighbor_erosion = vec2(0.0,TERRAIN);
	vec2 right_top_neighbor_erosion = vec2(0.0,TERRAIN);
	vec2 right_bottom_neighbor_erosion = vec2(0.0,TERRAIN);

	float H = TERRAIN;

	/*
	Get Neighboring values.
	=========================================================================
	get the height values from each of the 8 neighbors of the current cell.
	if the cell is on an edge, then give it a value that will not affect the calculations (set forth above).
	*/

	if(texCoord.x > 0)
	{ 
		ivec2 loc = texCoord + ivec2(-1,0);
		left_neighbor_outflow = imageLoad(water_outflow_flux,loc).RIGHT;
		vec4 neighborValues = imageLoad(terrain_water_sediment_heights_local_harness,loc);
		left_height = neighborValues.xy;
		left_neighbor_erosion.x = imageLoad(thermal_erosion_buffer,loc).RIGHT;
		left_neighbor_erosion.y = neighborValues.x;
		H = min(H,left_neighbor_erosion.y);
		if(texCoord.y > 0) 
		{
			loc += ivec2(0,-1);
			vec4 neighborValues = imageLoad(terrain_water_sediment_heights_local_harness,loc);
			left_bottom_neighbor_erosion.x = imageLoad(thermal_erosion_buffer_diagonals,loc).RIGHT_TOP;
			left_bottom_neighbor_erosion.y = neighborValues.x;
			H = min(H,left_bottom_neighbor_erosion.y);
			loc -= ivec2(0,-1);
		}
		if(texCoord.y < params.image_size.y-1)
		{
			loc += ivec2(0,1);
			vec4 neighborValues = imageLoad(terrain_water_sediment_heights_local_harness,loc);
			left_top_neighbor_erosion.x = imageLoad(thermal_erosion_buffer_diagonals,loc).RIGHT_BOTTOM;
			left_top_neighbor_erosion.y = neighborValues.x;
			H = min(H,left_top_neighbor_erosion.y);
		}
	}

	if(texCoord.x < params.image_size.x-1) 
	{
		ivec2 loc = texCoord + ivec2(1,0);
		vec4 neighborValues = imageLoad(terrain_water_sediment_heights_local_harness,loc);
		right_height = neighborValues.xy;
		right_neighbor_outflow = imageLoad(water_outflow_flux,loc).LEFT;
		right_neighbor_erosion.x = imageLoad(thermal_erosion_buffer,loc).LEFT;
		right_neighbor_erosion.y = neighborValues.x;
		H = min(H,right_neighbor_erosion.y);
		
		if(texCoord.y > 0) 
		{
			loc += ivec2(0,-1);
			vec4 neighborValues = imageLoad(terrain_water_sediment_heights_local_harness,loc);
			right_bottom_neighbor_erosion.x = imageLoad(thermal_erosion_buffer_diagonals,loc).LEFT_TOP;
			right_bottom_neighbor_erosion.y = neighborValues.x;
			H = min(H,right_bottom_neighbor_erosion.y);
			loc -= ivec2(0,-1);
		}
		if(texCoord.y < params.image_size.y-1)
		{
			loc += ivec2(0,1);
			vec4 neighborValues = imageLoad(terrain_water_sediment_heights_local_harness,loc);
			right_top_neighbor_erosion.x = imageLoad(thermal_erosion_buffer_diagonals,loc).LEFT_BOTTOM;
			right_top_neighbor_erosion.y = neighborValues.x;
			H = min(H,right_top_neighbor_erosion.y);
		}
	}

	if(texCoord.y > 0) 
	{
		ivec2 loc = texCoord + ivec2(0,-1);
		vec4 neighborValues = imageLoad(terrain_water_sediment_heights_local_harness,loc);
		bottom_height = neighborValues.xy;
		bottom_neighbor_outflow = imageLoad(water_outflow_flux,loc).TOP;
		bottom_neighbor_erosion.x = imageLoad(thermal_erosion_buffer,loc).TOP;
		bottom_neighbor_erosion.y = neighborValues.x;
		H = min(H,bottom_neighbor_erosion.y);
	}

	if(texCoord.y < params.image_size.y-1)
	{
		ivec2 loc = texCoord + ivec2(0,1);
		vec4 neighborValues = imageLoad(terrain_water_sediment_heights_local_harness,loc);
		top_height = neighborValues.xy;
		top_neighbor_outflow = imageLoad(water_outflow_flux,loc).BOTTOM;
		top_neighbor_erosion.x = imageLoad(thermal_erosion_buffer,loc).BOTTOM;
		top_neighbor_erosion.y = neighborValues.x;
		H = min(H,top_neighbor_erosion.y);
	}


	// Rain water increment.
	WATER += params.rain_rate * params.delta_t;

	/*
	Water flows and velocity.
	=========================================================================

	calculates the outflow of water from the cell based on the combined height of the terrain and the water.
	then creates a flow vector based on the outflow of the cell.

	We have a small problem with the water oscillating in a grid pattern.
	*/
	vec4 water_height_difference = vec4(left_height.y,right_height.y,top_height.y,bottom_height.y);
	vec4 terrain_height_difference = vec4(left_height.x,right_height.x,top_height.x,bottom_height.x);
	vec4 delta_height = vec4(TERRAIN + WATER) - (water_height_difference + terrain_height_difference);
	flows = max(vec4(0.0),flows + vec4(params.delta_t * params.pipe_area_length_ratio * params.gravity) * delta_height);

	float outFlow = flows.LEFT + flows.RIGHT + flows.TOP + flows.BOTTOM;
	float k = min(1.0,(WATER * params.cell_distance * params.cell_distance) / (params.delta_t * outFlow));

	// a second factor to dampen oscillation when all outflows are positive.
	water_height_difference = vec4(WATER) - water_height_difference;
	terrain_height_difference = vec4(TERRAIN) - terrain_height_difference;
	//if all elements of 'water_height_difference' are negative && the mean of 'terrain_height_difference' is approximately 0:
	// then reduce 'k';
	terrain_height_difference = abs(terrain_height_difference);
	float average_height_difference = terrain_height_difference.x + terrain_height_difference.y + terrain_height_difference.z + terrain_height_difference.w ;
	if(all(lessThan(water_height_difference,vec4(0.0))) && average_height_difference < WATER_DAMPENING_TERRAIN_HEIGHT_COEFFICIENT)
	{
		k *= clamp(average_height_difference / WATER_DAMPENING_TERRAIN_HEIGHT_COEFFICIENT,0.5,1.0);
	}


	outFlow *= k;
	flows *= vec4(k);

	//Calculate neighbor outflow into this cell i.e. inflow.
	float inFlow = left_neighbor_outflow + right_neighbor_outflow + top_neighbor_outflow + bottom_neighbor_outflow;

	WATER += (params.delta_t * (inFlow - outFlow)) / (cell_area);

	vec2 velocity = vec2(0.5) * vec2(
		left_neighbor_outflow - flows.LEFT + flows.RIGHT - right_neighbor_outflow,
		bottom_neighbor_outflow - flows.BOTTOM + flows.TOP - top_neighbor_outflow
		// this is correct because down flow is negative and up flow is positive.
	);

	
	/*
	Soil flow calculation.
	=========================================================================
	*/
	float maxSoilMovement = clamp(cell_area * params.delta_t * params.thermal_erosion_rate * 0.5 * (TERRAIN - H),0.0,TERRAIN *cell_area);
	//clamp the value to between zero and the max amount of soil in this cell.

	float A = 0.0;
	// x = erosion from cell, y = height of that cell, z = hardness of that cell
	left_neighbor_erosion.y = isTalusSlope(left_neighbor_erosion.y, TERRAIN, HARDNESS);
	A += left_neighbor_erosion.y;
	right_neighbor_erosion.y = isTalusSlope(right_neighbor_erosion.y, TERRAIN, HARDNESS);
	A += right_neighbor_erosion.y;
	top_neighbor_erosion.y = isTalusSlope(top_neighbor_erosion.y, TERRAIN, HARDNESS);
	A += top_neighbor_erosion.y;
	bottom_neighbor_erosion.y = isTalusSlope(bottom_neighbor_erosion.y, TERRAIN, HARDNESS);
	A += bottom_neighbor_erosion.y;
	left_top_neighbor_erosion.y = isTalusSlope(left_top_neighbor_erosion.y, TERRAIN, HARDNESS);
	A += left_top_neighbor_erosion.y;
	left_bottom_neighbor_erosion.y = isTalusSlope(left_bottom_neighbor_erosion.y, TERRAIN, HARDNESS);
	A += left_bottom_neighbor_erosion.y;
	right_top_neighbor_erosion.y = isTalusSlope(right_top_neighbor_erosion.y, TERRAIN, HARDNESS);
	A += right_top_neighbor_erosion.y;
	right_bottom_neighbor_erosion.y = isTalusSlope(right_bottom_neighbor_erosion.y, TERRAIN, HARDNESS);
	A += right_bottom_neighbor_erosion.y;
	
	vec4 delta_thermal_erosion = vec4(0.0);
	vec4 delta_thermal_erosion_diagonals = vec4(0.0);
	if(A > 0.00001)
	{

		delta_thermal_erosion = vec4(maxSoilMovement/A) * vec4(
		left_neighbor_erosion.y,
		right_neighbor_erosion.y,
		top_neighbor_erosion.y,
		bottom_neighbor_erosion.y);

		delta_thermal_erosion_diagonals = vec4(maxSoilMovement/A) * vec4(
		left_top_neighbor_erosion.y,
		right_top_neighbor_erosion.y,
		left_bottom_neighbor_erosion.y,
		right_bottom_neighbor_erosion.y);
	}

	/*

	Sediment Transportation.
	=========================================================================
	*/

	vec2 newLoc = vec2(texCoord) * vec2(params.delta_t) * velocity;

	ivec2 point11 = ivec2(floor(newLoc));
	ivec2 point22 = ivec2(ceil(newLoc));
	ivec2 point12 = ivec2(point11.x,point22.y);
	ivec2 point21 = ivec2(point22.x,point11.y);
	/*  
	p12--v1--p22
	 |   |    |
	 |   v3   |
	 |   |    |
	p11--v0--p21
	*/
	newLoc = fract(newLoc);

	float v0 =  sedimentAt(point21) * newLoc.x + sedimentAt(point11) * (1.0 - newLoc.x);
	float v1 =  sedimentAt(point22) * newLoc.x + sedimentAt(point12) * (1.0 - newLoc.x);

	SEDIMENT = v0 + newLoc.y * (v1-v0);


	/*
	Erosion deposition process.
	=========================================================================
	*/

	//Calculate the normal at the given point
	float deltaU = right_height.x - left_height.x;
	float deltaV = top_height.x - bottom_height.x;

	vec3 normal = normalize( cross( vec3( 0.0 ,deltaV, 2.0) ,vec3(2.0, deltaU, 0.0)));

	float tiltAngle = dot(-normal,vec3(velocity.x,0.0,velocity.y));// * length(velocity);

	float water_sediment_transport_capacity = params.sediment_capacity * tiltAngle * limit_ramp_function(WATER);

	if(SEDIMENT < water_sediment_transport_capacity)
	{
		//dissolve some soil in water
		float delta_erosion = min(params.delta_t * HARDNESS * params.soil_suspension_rate * (water_sediment_transport_capacity - SEDIMENT), TERRAIN);
		TERRAIN -= delta_erosion;
		SEDIMENT += delta_erosion;
		WATER += delta_erosion;
		/*
		For this section, the sediment technically becomes water, i.e. we add to the water height.
		*/
	}
	else
	{
		//dispose of some sediment
		float delta_deposition = min(params.delta_t * params.sediment_deposition_rate * ( SEDIMENT - water_sediment_transport_capacity), SEDIMENT);
		TERRAIN += delta_deposition;  // soil
		SEDIMENT -= delta_deposition;  // disolved sediment
		WATER -= delta_deposition;  // water height
	}

	/*
	Thermal erosion material amount calculation.
	=========================================================================
	*/

	// x = erosion from cell, y = height of that cell, z = hardness of that cell
	float terrain_soil_influx =   left_neighbor_erosion.x +
							right_neighbor_erosion.x +
							top_neighbor_erosion.x +
							bottom_neighbor_erosion.x +
							left_top_neighbor_erosion.x +
							right_top_neighbor_erosion.x +
							left_bottom_neighbor_erosion.x +
							right_bottom_neighbor_erosion.x;
	// x = erosion from cell, y = height of that cell, z = hardness of that cell
	float terrain_soil_outflux =  delta_thermal_erosion.LEFT +
							delta_thermal_erosion.RIGHT +
							delta_thermal_erosion.TOP +
							delta_thermal_erosion.BOTTOM +
							delta_thermal_erosion_diagonals.LEFT_TOP +
							delta_thermal_erosion_diagonals.RIGHT_TOP +
							delta_thermal_erosion_diagonals.LEFT_BOTTOM +
							delta_thermal_erosion_diagonals.RIGHT_BOTTOM;
	TERRAIN += terrain_soil_influx - terrain_soil_outflux;
	
	/*
	value clamping / sanity check.
	=========================================================================
	*/

	WATER = max(0.0,WATER);
	SEDIMENT = clamp(SEDIMENT,0.0,WATER);//this creates a small problem where we lose sediment in low water.
	TERRAIN = clamp(TERRAIN,0,2000.0);
	
	HARDNESS = clamp(
		HARDNESS - (params.delta_t * params.sediment_softening_rate * params.soil_suspension_rate * ( SEDIMENT - water_sediment_transport_capacity)),
		params.minimum_soil_hardness,
		1.0);

   


	/*
	Water Evaporation.
	=========================================================================
	*/
	WATER -= clamp(WATER * params.evaporation_rate,0.0,params.max_evaporation_amount);

	imageStore(thermal_erosion_buffer_write,texCoord,delta_thermal_erosion);
	imageStore(thermal_erosion_buffer_diagonals_write,texCoord,delta_thermal_erosion_diagonals);
	imageStore(terrain_water_sediment_heights_local_harness_write,texCoord,previous_twsh);
	imageStore(water_outflow_flux_write,texCoord,flows);
}
