extends Camera3D

const MOUSE_MAX_UP_ANGLE:float = 0.9 # dot product limit of 1 minus the max angle
const INITIAL_FORWARD_DIRECTION:Vector3 = Vector3(0.0,0.0,-1.0)
const INITIAL_RIGHT_DIRECTION:Vector3 = Vector3(1.0,0.0,0.0)
const WORLD_UP:Vector3 = Vector3(0.0,1.0,0.0)

@export var movementSpeed: float = 0.05
@export var mouse_move_sensitivity:float = 0.03
var rightLeft: float = 0.0
var forwardBackward: float = 0.0
var upDown: float = 0.0
var rightClick:bool = false
var middleClick:bool = false

func _input(event: InputEvent) -> void:
	if(event is InputEventMouseMotion):
		var mouseMove: Vector2 = event.relative
		if(rightClick):
			self.rotate_y(-mouseMove.x * mouse_move_sensitivity)
			if(!is_zero_approx(mouseMove.y)):
				var lookAngle:float = (self.quaternion * INITIAL_FORWARD_DIRECTION).dot(WORLD_UP)
				#print(lookAngle)
				if((lookAngle < MOUSE_MAX_UP_ANGLE && mouseMove.y < 0.0) # if looking up and want to move down.
				|| (lookAngle > -MOUSE_MAX_UP_ANGLE && mouseMove.y > 0.0)):# if looking down and want to move up.
					#print("moveVertical")
					var rightDir:Vector3 = self.quaternion * INITIAL_RIGHT_DIRECTION
					self.rotate(rightDir,-mouseMove.y * mouse_move_sensitivity)
		elif(middleClick):
			upDown = mouseMove.x * movementSpeed
			forwardBackward = mouseMove.y * movementSpeed
	elif(event is InputEventMouseButton):
		if(event.button_index == MOUSE_BUTTON_RIGHT):
			rightClick = event.is_pressed()
		elif(event.button_index == MOUSE_BUTTON_MIDDLE):
			middleClick = event.is_pressed()
		elif(event.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			forwardBackward = -1.0 * movementSpeed
		elif(event.button_index == MOUSE_BUTTON_WHEEL_UP):
			forwardBackward = 1.0 * movementSpeed

	
# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(_delta: float) -> void:
	
	self.position = lerp(self.position,self.position+self.quaternion * (INITIAL_FORWARD_DIRECTION * forwardBackward + INITIAL_RIGHT_DIRECTION * rightLeft),0.5)
	rightLeft = 0.0
	forwardBackward = 0.0
	upDown = 0.0
