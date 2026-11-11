extends Node3D
## A cosmetic pellet mark placed on an environment surface.

@onready var projected_decal: Decal = $ProjectedDecal
@onready var surface_mark: MeshInstance3D = $SurfaceMark

func _ready() -> void:
	var use_projection := DisplayServer.get_name() != "headless" and RenderingServer.get_current_rendering_method() != "gl_compatibility"
	projected_decal.visible = use_projection
	surface_mark.visible = not use_projection

## Positions the mark at a world-space ray impact and aligns its local Y axis with the receiving surface.
func place(impact_position: Vector3, surface_normal: Vector3, shot_direction: Vector3) -> void:
	if surface_normal.is_zero_approx():
		hide()
		return
	var up := surface_normal.normalized()
	var forward := shot_direction.slide(up)
	if forward.length_squared() < 0.0025:
		var axis := Vector3.FORWARD if absf(up.dot(Vector3.FORWARD)) < 0.9 else Vector3.UP
		forward = axis.slide(up)
	forward = forward.normalized()
	global_transform = Transform3D(Basis(up.cross(forward), up, forward), impact_position)
