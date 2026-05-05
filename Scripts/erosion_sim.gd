extends MeshInstance3D


const TERRAIN_SIZE: int = 512*2
const TERRAIN_HEIGHT: float = 1000.0

@export var run_sim: bool = true
@export var save_image_on_completion:bool = false
@export_range(0.1,20.0) var gravity :float= 9.81
@export_range(0.0,0.15) var rain_rate :float= 0.012
@export_range(0.1,60) var pipe_area :float= 20.0
@export_range(0.1,20) var cell_distance :float= 5
@export_range(0.1,3.0) var  sediment_capacity :float = 1.0
@export_range(0.0,1.0) var  thermal_erosion_rate :float = 0.15
@export_range(0.1,2.0) var  soil_suspension_rate :float = 0.5
@export_range(0.1,3.0) var  sediment_deposition_rate :float = 1.0
@export_range(0.0,10.0) var  sediment_softening_rate :float = 5.0
@export_range(0.0,40.0) var  maximum_erosion_depth :float = 10.0
## Coefficient to the hardness of the cell for thermal erosion.
## If hardness * this + bais is greater than the slope then that cell errodes.
@export_range(0.0,5.0) var  talus_angle_tangent_coefficient :float = 1.6
## bais of the cell for thermal erosion.
## If hardness * coefficent + this is greater than the slope then that cell errodes.
@export_range(0.0,5.0) var  talus_angle_tangent_bias :float = 1.0
@export_range(0.0,1.0) var  minimum_soil_hardness :float = 0.1
@export_range(0.0,2.0) var  soil_hardness :float = 0.5
@export_range(0.0,10000.0) var  evaporation_rate :float = 70.0:
	set(x):
		evaporation_rate = x
		print("evaporation_rate: ", 1.0/evaporation_rate)
@export_range(0.1,1.0) var  max_evaporation_amount :float = 1.0

var rd:RenderingDevice = RenderingServer.get_rendering_device()
var shader		: RID
var pipeline 	: RID
var image_set1 	: Array = [RID(),RID(),RID(),RID()]
var uniform_set1: RID
var image_set2 	: Array = [RID(),RID(),RID(),RID()]
var uniform_set2: RID
var currentSet:int = 0

var noiseTextureReady:bool = false
var soil_image :RID

func loadShader(filePath : String) -> RID:
	# Load GLSL shader
	var shader_file:RDShaderFile = load(filePath)
	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	print(shader_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE))
	
	return rd.shader_create_from_spirv(shader_spirv)

func _createRD_Image(texSize:int,format:RenderingDevice.DataFormat, data:PackedByteArray = [])->RID:
	var tex_format: RDTextureFormat = RDTextureFormat.new()
	tex_format.format = format
	tex_format.texture_type = rd.TEXTURE_TYPE_2D
	tex_format.width = texSize
	tex_format.height = texSize
	tex_format.depth = 1
	tex_format.array_layers = 1
	tex_format.mipmaps = 1
	tex_format.usage_bits = (
			rd.TEXTURE_USAGE_SAMPLING_BIT |
			rd.TEXTURE_USAGE_STORAGE_BIT |
			rd.TEXTURE_USAGE_CAN_COPY_TO_BIT |
			rd.TEXTURE_USAGE_CAN_COPY_FROM_BIT
		)
	return rd.texture_create(tex_format, RDTextureView.new(), [data])

func _copyRD_Image(src:RID,dst:RID,imageSize:int)->void:
	var err = rd.texture_copy(src,dst,
	Vector3(0.0,0.0,0.0),
	Vector3(0.0,0.0,0.0),
	Vector3(float(imageSize),float(imageSize),0.0),
	0,0,0,0
	)
	if(err != OK):
		print(error_string(err))

func _create_uniform(uniform:RID, type:RenderingDevice.UniformType, binding:int) ->RDUniform:
	var uniform_buffer := RDUniform.new()
	uniform_buffer.uniform_type = type
	uniform_buffer.binding = binding 
	uniform_buffer.add_id(uniform)
	return uniform_buffer

func _get_push_constant(delta:float) -> PackedByteArray:
	var arr: PackedByteArray = PackedInt32Array([TERRAIN_SIZE,TERRAIN_SIZE,0,0]).to_byte_array()
	
	arr.append_array(PackedFloat32Array([
		gravity,
		rain_rate,
		delta,
		pipe_area / cell_distance,
		cell_distance,
		sediment_capacity,
		thermal_erosion_rate,
		soil_suspension_rate,
		sediment_deposition_rate,
		sediment_softening_rate,
		maximum_erosion_depth,
		talus_angle_tangent_coefficient,
		talus_angle_tangent_bias,
		minimum_soil_hardness,
		1.0 /evaporation_rate,
		max_evaporation_amount
	]).to_byte_array())
	
	return arr

func _dispatch_compute_shaders(delta:float):
	
	var push_constants: PackedByteArray = _get_push_constant(delta)
	
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set1, 0)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set2, 1)
	
	rd.compute_list_set_push_constant(compute_list,push_constants,push_constants.size())
	
	rd.compute_list_dispatch(compute_list, TERRAIN_SIZE, TERRAIN_SIZE, 1)
	rd.compute_list_end()
	
	#copy the images back to the first set to run the process again.
	for i in range(image_set1.size()):
		_copyRD_Image(image_set2[i],image_set1[i],TERRAIN_SIZE)
	currentSet += 1
	currentSet %= 2
	#_copyRD_Image(image_set2[1],image_set1[1],TERRAIN_SIZE)

func getNoiseFunctionToImage() -> PackedByteArray:
	noiseTextureReady = false
	var height_map = NoiseTexture2D.new()
	height_map.noise = FastNoiseLite.new()
	height_map.noise.set_seed(randi())
	#texture.noise.set_fractal_type(FastNoiseLite.FRACTAL_NONE)
	height_map.noise.set_noise_type(FastNoiseLite.TYPE_SIMPLEX)
	height_map.noise.set_frequency(2.0 / (float(TERRAIN_SIZE)))
	#texture.noise.set_fractal_octaves(2)
	#texture.noise.set_fractal_gain(0.90)
	height_map.set_generate_mipmaps(false)
	height_map.set_normalize(false)
	height_map.set_width(TERRAIN_SIZE)
	height_map.set_height(TERRAIN_SIZE)
	
	var soil_hardness_map = NoiseTexture2D.new()
	soil_hardness_map.noise = FastNoiseLite.new()
	soil_hardness_map.noise.set_seed(randi())
	soil_hardness_map.noise.set_fractal_type(FastNoiseLite.FRACTAL_NONE)
	soil_hardness_map.noise.set_frequency(8.0 / (float(TERRAIN_SIZE)))
	#soil_hardness_map.noise.set_fractal_gain(0.90)
	soil_hardness_map.set_generate_mipmaps(false)
	soil_hardness_map.set_normalize(false)
	@warning_ignore("integer_division")
	soil_hardness_map.set_width(TERRAIN_SIZE/4)
	@warning_ignore("integer_division")
	soil_hardness_map.set_height(TERRAIN_SIZE/4)
	
	await height_map.changed
	await soil_hardness_map.changed
	noiseTextureReady = true
	#clear out the data so that only the first channel has noise
	var im:Image = height_map.get_image()
	var hardness:Image = soil_hardness_map.get_image()
	im.convert(Image.FORMAT_RGBAF)
	for x in range(im.get_width()):
		for y in range(im.get_height()):
			var original_color = im.get_pixel(x,y)
			var height = original_color.r;
			original_color.r = (0.9*original_color.r + 0.1)**2 * TERRAIN_HEIGHT
			original_color.g = 0.0
			original_color.b = 0.0
			original_color.a = clampf(hardness.get_pixel(
				int( soil_hardness_map.get_width() * (float(x) / im.get_width())),
				int( soil_hardness_map.get_height() * (float(x) / im.get_height()))
			).r * soil_hardness * clampf((1.0 - height),0.25,1.0), minimum_soil_hardness,1.0)
			im.set_pixel(x,y,original_color)
	#rd.free_rid(rd_image)
	
	#print(im.get_pixel(128,128))
	#print(im.get_pixel(0,128))
	#print(im.get_pixel(128,75))
	
	return im.get_data()

func _save_soil_image():
	var imageData : PackedByteArray = rd.texture_get_data(image_set1[0],0)
	var im :Image = Image.create_from_data(TERRAIN_SIZE,TERRAIN_SIZE,false,Image.FORMAT_RGBAF,imageData)
	im.save_exr("res://Assets/Terrain_%d.exr" % TERRAIN_SIZE,false)
	

func _ready() -> void:
	#start by filling the shaders.
	shader = loadShader("res://shaders/Hydralic_erosion.glsl")
	
	var fractalNoiseData = await getNoiseFunctionToImage()
	var zeros_for_data = PackedByteArray()
	zeros_for_data.resize(fractalNoiseData.size())
	zeros_for_data.fill(0)

	#generate image buffers
	for i in range(image_set1.size()):
		if(i == 0):
			image_set1[0] = _createRD_Image(TERRAIN_SIZE,rd.DATA_FORMAT_R32G32B32A32_SFLOAT,fractalNoiseData)
			image_set2[0] = _createRD_Image(TERRAIN_SIZE,rd.DATA_FORMAT_R32G32B32A32_SFLOAT,fractalNoiseData)
		else:
			image_set1[i] = _createRD_Image(TERRAIN_SIZE,rd.DATA_FORMAT_R32G32B32A32_SFLOAT,zeros_for_data)
			image_set2[i] = _createRD_Image(TERRAIN_SIZE,rd.DATA_FORMAT_R32G32B32A32_SFLOAT,zeros_for_data)
			
	
	#fill two uniform sets with the images.
	var uniforms1 :Array = [RID(),RID(),RID(),RID()]
	var uniforms2 :Array = [RID(),RID(),RID(),RID()]
	for i in range(image_set1.size()):
		uniforms1[i] = _create_uniform(image_set1[i],rd.UNIFORM_TYPE_IMAGE,i)
		uniforms2[i] = _create_uniform(image_set2[i],rd.UNIFORM_TYPE_IMAGE,i)
	
	
	#ping pongs the image buffers so that no shader is reading AND writing to the same buffer
	#we will read from set 0 and write to set 1 then the next shader flips the sets.
	uniform_set1 = rd.uniform_set_create(uniforms1, shader, 0)
	uniform_set2 = rd.uniform_set_create(uniforms2, shader, 1)
		
	
	#create the pipelines from those shaders
	pipeline = rd.compute_pipeline_create(shader)

	#Set the mesh shader image to the first soil texture
	soil_image = RenderingServer.texture_rd_create(image_set1[0])
	#print(soil_image)
	self.mesh.material.set_shader_parameter("height_map",soil_image)
	self.mesh.material.set_shader_parameter("height_map_size",Vector2(float(TERRAIN_SIZE),float(TERRAIN_SIZE)))
	self.mesh.material.next_pass.set_shader_parameter("height_map",soil_image)
	self.mesh.material.next_pass.set_shader_parameter("height_map_size",Vector2(float(TERRAIN_SIZE),float(TERRAIN_SIZE)))
	
	self.mesh.material.set_shader_parameter("height_map_scale", 0.25/float(TERRAIN_HEIGHT))
	self.mesh.material.next_pass.set_shader_parameter(
		"height_map_scale",
		self.mesh.material.get_shader_parameter("height_map_scale")
	)
	
	self.mesh.material.set_shader_parameter("max_height_map_val", TERRAIN_HEIGHT)
	self.mesh.material.next_pass.set_shader_parameter(
		"max_height_map_val",
		self.mesh.material.get_shader_parameter("max_height_map_val")
	)
	currentSet = 0
	#_dispatch_compute_shaders(0.001)
	
func _exit_tree() -> void:
	#save the image used to generate the terrain.
	if(save_image_on_completion):
		_save_soil_image()
	
	rd.free_rid(shader)
	rd.free_rid(pipeline)
	rd.free_rid(uniform_set1)
	rd.free_rid(uniform_set2)
	for i in range(2):
		rd.free_rid(image_set1[i])
		rd.free_rid(image_set2[i])

func _process(delta: float) -> void:
	if(run_sim):
		_dispatch_compute_shaders(delta)
		if(TERRAIN_SIZE <1500):
			_dispatch_compute_shaders(delta)
	
