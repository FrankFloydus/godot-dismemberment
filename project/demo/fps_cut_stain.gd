extends RefCounted
## Applies a bounded blood layer to the exterior of a pose-baked fragment.

const STAIN_SHADER := preload("res://demo/fps_cut_stain.gdshader")
const NOISE := preload("res://addons/godot-dismemberment/textures/cloud_noise.png")
const HISTORY_META := &"plane_slice_stains"
const CAP_NAME := "Slice Cap"
const SEAM_MARGIN := 0.04
const CAP_TOLERANCE := 0.001
const PLANE_PARAMETERS: Array[StringName] = [
	&"stain_plane_0", &"stain_plane_1", &"stain_plane_2", &"stain_plane_3",
]
const MIN_PARAMETERS: Array[StringName] = [
	&"stain_min_0", &"stain_min_1", &"stain_min_2", &"stain_min_3",
]
const MAX_PARAMETERS: Array[StringName] = [
	&"stain_max_0", &"stain_max_1", &"stain_max_2", &"stain_max_3",
]

var _stain := ShaderMaterial.new()
var _materials: Dictionary = {}
var _untextured := StandardMaterial3D.new()


func _init() -> void:
	_stain.shader = STAIN_SHADER
	_stain.set_shader_parameter(&"stain_noise", NOISE)
	_untextured.next_pass = _stain


func apply(visual: MeshInstance3D, source: MeshInstance3D, local_plane: Plane) -> void:
	var mesh := visual.mesh as ArrayMesh
	if mesh == null or mesh.get_surface_count() == 0:
		return
	var exterior: Array[int] = []
	for surface in mesh.get_surface_count():
		if mesh.surface_get_name(surface) != CAP_NAME:
			exterior.append(surface)
	if exterior.is_empty():
		return

	var history: Array = []
	var mesh_bounds := mesh.get_aabb().grow(CAP_TOLERANCE)
	if is_instance_valid(source) and source.has_meta(HISTORY_META):
		for previous: Dictionary in source.get_meta(HISTORY_META):
			var bounds: AABB = previous.bounds
			if mesh_bounds.intersects(bounds):
				history.append(previous)
	var current := _latest_seam(mesh, local_plane.normalized())
	if not current.is_empty():
		if history.size() == PLANE_PARAMETERS.size():
			history.pop_front()
		history.append(current)
	if history.is_empty():
		return

	visual.set_meta(HISTORY_META, history)
	for surface in exterior:
		var base := visual.get_surface_override_material(surface)
		if base == null:
			base = mesh.surface_get_material(surface)
		visual.set_surface_override_material(surface, _with_stain(base))

	for i in PLANE_PARAMETERS.size():
		if i >= history.size():
			visual.set_instance_shader_parameter(MIN_PARAMETERS[i], Vector4.ZERO)
			continue
		var seam: Dictionary = history[i]
		var bounds: AABB = seam.bounds
		var low := bounds.position
		var high := bounds.end
		visual.set_instance_shader_parameter(PLANE_PARAMETERS[i], seam.plane)
		visual.set_instance_shader_parameter(MIN_PARAMETERS[i], Vector4(low.x, low.y, low.z, 1.0))
		visual.set_instance_shader_parameter(MAX_PARAMETERS[i], Vector4(high.x, high.y, high.z, 0.0))


func _latest_seam(mesh: ArrayMesh, local_plane: Plane) -> Dictionary:
	# Native slicing publishes the new cap after all retained source surfaces.
	var surface := mesh.get_surface_count() - 1
	if mesh.surface_get_name(surface) != CAP_NAME or local_plane.normal.is_zero_approx():
		return {}
	var positions: PackedVector3Array = mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]
	if positions.is_empty():
		return {}
	var bounds := AABB(positions[0], Vector3.ZERO)
	for position in positions:
		if absf(local_plane.distance_to(position)) > CAP_TOLERANCE:
			return {}
		bounds = bounds.expand(position)
	return {"plane": local_plane, "bounds": bounds.grow(SEAM_MARGIN)}


func _with_stain(base: Material) -> Material:
	if base == null:
		return _untextured
	if base == _untextured or base == _stain:
		return base
	if _materials.has(base):
		return _materials[base]
	if _materials.find_key(base) != null:
		return base
	var wrapped := base.duplicate() as Material
	_materials[base] = wrapped
	wrapped.next_pass = _stain if base.next_pass == null else _with_stain(base.next_pass)
	return wrapped
