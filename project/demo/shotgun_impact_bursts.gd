extends Node3D
## Reuses short-lived surface bursts independently of the persistent pellet marks.

const BURST := preload("res://demo/shotgun_impact_burst.tscn")
const MAX_BURSTS := 32

var _bursts: Array[Node3D] = []
var _next_burst := 0
var _spark_gravity: Vector3
var _smoke_gravity: Vector3

func _ready() -> void:
	for index in MAX_BURSTS:
		var burst := BURST.instantiate() as Node3D
		add_child(burst)
		_bursts.append(burst)
	_spark_gravity = (_bursts[0].get_node(^"Sparks") as CPUParticles3D).gravity
	_smoke_gravity = (_bursts[0].get_node(^"Smoke") as CPUParticles3D).gravity

## Emits at the ray contact, with the contact transform's Y axis pointing out of the surface.
func emit_at(contact: Transform3D, shot_direction := Vector3.ZERO, dusty := false) -> void:
	var burst := _bursts[_next_burst]
	_next_burst = (_next_burst + 1) % _bursts.size()
	burst.global_transform = contact
	burst.reset_physics_interpolation()
	# Simulate from the slot's local origin. Express gravity in that same basis.
	var to_local_basis := contact.basis.transposed()
	var flash := burst.get_node(^"StrikeFlash") as CPUParticles3D
	var sparks := burst.get_node(^"Sparks") as CPUParticles3D
	var smoke := burst.get_node(^"Smoke") as CPUParticles3D
	var incoming := to_local_basis * shot_direction.normalized()
	var reflected := Vector3(incoming.x, absf(incoming.y), incoming.z)
	sparks.direction = Vector3.UP.lerp(reflected, 0.54).normalized()
	sparks.gravity = to_local_basis * _spark_gravity
	smoke.gravity = to_local_basis * _smoke_gravity
	flash.color = Color(0.72, 0.67, 0.60, 0.10) if dusty else Color.WHITE
	sparks.color = Color(0.58, 0.53, 0.47, 0.22) if dusty else Color.WHITE
	smoke.color = Color(1.0, 1.0, 1.0, 1.0 if dusty else 0.56)
	flash.restart()
	sparks.restart()
	smoke.restart()
