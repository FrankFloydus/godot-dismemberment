extends RefCounted
## Cut the demo's authored interior volumes in the same mesh space as the exterior.

const InteriorAsset := preload("res://demo/fps_slice_interior_asset.gd")
const LAYERS_META := &"slice_interior_layers"
const VISUAL_GROUP := &"slice_interior_visual"
const CAP := "Slice Cap"
const DEFAULT_CAP_PATH := "res://addons/godot-dismemberment/materials/slice_cap.tres"
const BACKING := preload("res://demo/assets/slice_interior/backing.tres")
const EPSILON := 0.000001
const CONTOUR_TOLERANCE := 0.00005


static func prepare() -> void:
	InteriorAsset.prepare()


static func apply(source: MeshInstance3D, skeleton: Skeleton3D, local_plane: Plane,
		positive_visuals: Array, negative_visuals: Array, override_material: Material,
		missing_bones: PackedStringArray = [], retain_unmatched := false) -> void:
	var layers: Array[Dictionary] = []
	if source.has_meta(LAYERS_META):
		layers.assign(source.get_meta(LAYERS_META))
	elif skeleton != null:
		layers = InteriorAsset.posed_layers(source, skeleton)
	if layers.is_empty():
		return

	var normal := local_plane.normal.abs()
	var axis := normal.max_axis_index()
	var positive_caps: Array[Dictionary] = []
	var negative_caps: Array[Dictionary] = []
	var caps_loaded := false
	# Localized severing publishes one remainder, including shells on either
	# side of the plane that were outside the selected limb.
	var retained: MeshInstance3D = negative_visuals.front() if retain_unmatched else null
	for layer in layers:
		if skeleton != null and not missing_bones.is_empty() \
				and _is_missing(skeleton, layer.bone, missing_bones):
			continue
		var mesh: ArrayMesh = layer.mesh
		var transform: Transform3D = layer.transform
		var normal_in_part := transform.basis.transposed() * local_plane.normal
		var length := normal_in_part.length()
		if not is_finite(length) or length < EPSILON:
			continue
		var part_plane := Plane(normal_in_part / length,
			(local_plane.d - local_plane.normal.dot(transform.origin)) / length)
		var part_bounds := mesh.get_aabb()
		var distance := part_plane.distance_to(part_bounds.get_center())
		var radius := part_plane.normal.abs().dot(part_bounds.size) * 0.5
		var destination: MeshInstance3D
		if absf(distance) < radius - EPSILON:
			var material: Material = override_material if override_material != null else layer.cap_material
			var result: Dictionary = ClassDB.class_call_static(&"MeshPlaneSlice", &"slice_mesh",
				mesh, part_plane, material, EPSILON)
			var positive := result.get("positive_mesh") as ArrayMesh
			var negative := result.get("negative_mesh") as ArrayMesh
			if positive != null and negative != null:
				if not caps_loaded:
					positive_caps = _cap_footprints(positive_visuals, local_plane, axis)
					negative_caps = _cap_footprints(negative_visuals, local_plane, axis)
					caps_loaded = true
				var footprint := _layer_footprint(positive, transform, axis)
				var first := _find_cap(positive_caps, footprint)
				var second := _find_cap(negative_caps, footprint)
				if first != null and second != null:
					_store_split(first, layer, positive)
					_store_split(second, layer, negative)
					continue
				# A layer crossing the shell would draw over the surrounding skin.
				# With localized severing, the plane may also cross unselected pieces.
				if first == null:
					_store(retained, layer)
				continue

		var positive_side := distance >= 0.0
		var visuals := positive_visuals if positive_side else negative_visuals
		var bounds: AABB = layer.get("source_bounds", transform * part_bounds)
		destination = _find_volume(visuals, bounds)
		if destination == null and not layer.has("source_bounds"):
			bounds = _source_bounds(mesh, transform)
			destination = _find_volume(visuals, bounds)
		_store(destination if destination != null else retained, layer)

	if override_material == null:
		for visual: MeshInstance3D in positive_visuals + negative_visuals:
			_apply_backing(visual)


static func _is_missing(skeleton: Skeleton3D, name: StringName, missing: PackedStringArray) -> bool:
	var bone := skeleton.find_bone(name)
	while bone >= 0:
		if String(skeleton.get_bone_name(bone)) in missing:
			return true
		bone = skeleton.get_bone_parent(bone)
	return false


static func _find_volume(visuals: Array, volume: AABB) -> MeshInstance3D:
	var closest: MeshInstance3D
	var closest_distance := INF
	var point := volume.get_center()
	for visual: MeshInstance3D in visuals:
		var bounds := visual.mesh.get_aabb().grow(CONTOUR_TOLERANCE)
		if bounds.encloses(volume):
			var distance := bounds.get_center().distance_squared_to(point)
			if distance < closest_distance:
				closest = visual
				closest_distance = distance
	return closest


static func _source_bounds(mesh: ArrayMesh, transform: Transform3D) -> AABB:
	var bounds := AABB()
	var has_bounds := false
	for surface in mesh.get_surface_count():
		var vertices: PackedVector3Array = mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]
		for point in vertices:
			var position := transform * point
			if has_bounds:
				bounds = bounds.expand(position)
			else:
				bounds = AABB(position, Vector3.ZERO)
				has_bounds = true
	return bounds


static func _project(point: Vector3, axis: int) -> Vector2:
	match axis:
		0: return Vector2(point.y, point.z)
		1: return Vector2(point.x, point.z)
		_: return Vector2(point.x, point.y)


static func _cap_footprints(visuals: Array, plane: Plane, axis: int) -> Array[Dictionary]:
	var footprints: Array[Dictionary] = []
	for visual: MeshInstance3D in visuals:
		var mesh := visual.mesh as ArrayMesh
		var surface := mesh.get_surface_count() - 1
		if surface < 0 or mesh.surface_get_name(surface) != CAP:
			continue
		var arrays := mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if vertices.is_empty() or absf(plane.distance_to(vertices[0])) > CONTOUR_TOLERANCE:
			continue
		var edges := _rim_edges(arrays[Mesh.ARRAY_INDEX])
		var successors := {}
		for edge: Vector2i in edges.values():
			successors[edge.x] = edge.y
		var loops: Array[PackedVector2Array] = []
		while not successors.is_empty():
			var first: int = successors.keys()[0]
			var next := first
			var contour := PackedVector2Array()
			while successors.has(next):
				contour.append(_project(vertices[next], axis))
				var current := next
				next = successors[current]
				successors.erase(current)
			if next == first and contour.size() >= 3:
				loops.append(contour)
		if not loops.is_empty():
			footprints.append({"visual": visual, "loops": loops})
	return footprints


static func _layer_footprint(mesh: ArrayMesh, transform: Transform3D, axis: int) -> PackedVector2Array:
	var surface := mesh.get_surface_count() - 1
	var vertices: PackedVector3Array = mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]
	var points := PackedVector2Array()
	points.resize(vertices.size())
	for index in vertices.size():
		points[index] = _project(transform * vertices[index], axis)
	return points


static func _find_cap(footprints: Array[Dictionary], points: PackedVector2Array) -> MeshInstance3D:
	for footprint in footprints:
		var contains := true
		for point in points:
			var inside := false
			for contour: PackedVector2Array in footprint.loops:
				if Geometry2D.is_point_in_polygon(point, contour):
					inside = not inside
			if not inside:
				contains = false
				break
		if contains:
			return footprint.visual
	return null


static func _rim_edges(indices: PackedInt32Array) -> Dictionary:
	var edges := {}
	for index in range(0, indices.size(), 3):
		_toggle_edge(edges, indices[index], indices[index + 1])
		_toggle_edge(edges, indices[index + 1], indices[index + 2])
		_toggle_edge(edges, indices[index + 2], indices[index])
	return edges


static func _toggle_edge(edges: Dictionary, a: int, b: int) -> void:
	var key := Vector2i(mini(a, b), maxi(a, b))
	if not edges.erase(key):
		edges[key] = Vector2i(a, b)


static func _store_split(visual: MeshInstance3D, layer: Dictionary, mesh: ArrayMesh) -> void:
	var half := layer.duplicate()
	half.mesh = mesh
	half.source_bounds = _source_bounds(mesh, layer.transform)
	half.visible_mesh = _exposed_caps(mesh, layer)
	_store(visual, half)


static func _store(visual: MeshInstance3D, layer: Dictionary) -> void:
	if visual == null:
		return
	var layers: Array = visual.get_meta(LAYERS_META, [])
	layers.append(layer)
	visual.set_meta(LAYERS_META, layers)
	var mesh := layer.get("visible_mesh") as ArrayMesh
	if mesh == null or mesh.get_surface_count() == 0:
		return
	var interior := MeshInstance3D.new()
	interior.name = layer.name
	interior.mesh = mesh
	interior.transform = layer.transform
	interior.layers = visual.layers
	interior.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	interior.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	interior.add_to_group(VISUAL_GROUP)
	visual.add_child(interior)


static func _apply_backing(visual: MeshInstance3D) -> void:
	var has_interiors := false
	for child in visual.get_children():
		if child.is_in_group(VISUAL_GROUP):
			has_interiors = true
			break
	if not has_interiors:
		return
	var mesh := visual.mesh as ArrayMesh
	for surface in mesh.get_surface_count():
		if mesh.surface_get_name(surface) != CAP:
			continue
		var material := mesh.surface_get_material(surface)
		if material != null and material.resource_path == DEFAULT_CAP_PATH:
			visual.set_surface_override_material(surface, BACKING)


static func _exposed_caps(volume: ArrayMesh, layer: Dictionary) -> ArrayMesh:
	var visible := ArrayMesh.new()
	var transform: Transform3D = layer.transform
	var inverse := transform.basis.inverse()
	var normal_basis := inverse.transposed()
	for surface in volume.get_surface_count():
		if volume.surface_get_name(surface) != CAP:
			continue
		var arrays := volume.surface_get_arrays(surface)
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		if normals.is_empty():
			continue
		var normal := normals[0]
		var outward := inverse * (normal_basis * normal).normalized()
		var material := volume.surface_get_material(surface)
		var profile: StringName = layer.get("profile", &"soft")
		_round_face(arrays, normal, outward, layer.relief, profile, material == layer.cap_material)
		visible.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		visible.surface_set_material(visible.get_surface_count() - 1, material)
		visible.surface_set_name(visible.get_surface_count() - 1, CAP)
	return visible


static func _round_face(arrays: Array, normal: Vector3, outward: Vector3, relief: float,
		profile: StringName, paint_rim: bool) -> void:
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var original_indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var rim := _rim_edges(original_indices)
	var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var count := vertices.size()
	var center := Vector3.ZERO
	var center_uv := Vector2.ZERO
	for index in count:
		center += vertices[index]
		center_uv += uv[index]
	center /= float(count)
	center_uv /= float(count)

	# Every authored volume is closed, but a glancing recut can produce an
	# irregular face. Use a fan only when its anchor lies inside every edge.
	for edge: Vector2i in rim.values():
		var a := vertices[edge.x]
		var b := vertices[edge.y]
		if (b - a).cross(center - a).dot(normal) >= 0.0:
			for index in count:
				vertices[index] += outward * 0.00017
			arrays[Mesh.ARRAY_VERTEX] = vertices
			return

	var hard := profile == &"bone" or profile == &"core"
	var radial_steps := PackedFloat32Array([0.0, 0.20, 0.55])
	var heights := PackedFloat32Array([0.0, 0.53, 0.92])
	if profile == &"bone":
		heights = PackedFloat32Array([0.0, 0.88, 0.99])
	elif profile == &"core":
		heights = PackedFloat32Array([0.94, 0.99, 1.0])
	var tip := count * radial_steps.size()
	var positions := PackedVector3Array()
	positions.resize(tip + 1)
	var texcoords := PackedVector2Array()
	texcoords.resize(tip + 1)
	var colors := PackedColorArray()
	if paint_rim:
		colors.resize(tip + 1)
	for ring in radial_steps.size():
		for point in count:
			var index := ring * count + point
			var position := vertices[point].lerp(center, radial_steps[ring])
			var variation := 1.0 if hard else 0.9 + sin(position.dot(Vector3(91.0, 67.0, 113.0))) * 0.1
			positions[index] = position + outward * (0.00017 + heights[ring] * relief * variation)
			texcoords[index] = uv[point].lerp(center_uv, radial_steps[ring])
			if paint_rim:
				var edge_blend := minf(1.0, ring * 0.65)
				colors[index] = Color(edge_blend, 1.0, 1.0)
	positions[tip] = center + outward * (0.00017 + relief * (1.0 if hard else 0.96))
	texcoords[tip] = center_uv
	if paint_rim:
		colors[tip] = Color.WHITE
	var indices := PackedInt32Array()
	indices.resize(rim.size() * 15)
	var cursor := 0
	for edge: Vector2i in rim.values():
		for ring in 2:
			var a := ring * count + edge.x
			var b := ring * count + edge.y
			indices[cursor] = a
			indices[cursor + 1] = b
			indices[cursor + 2] = a + count
			indices[cursor + 3] = b
			indices[cursor + 4] = b + count
			indices[cursor + 5] = a + count
			cursor += 6
		indices[cursor] = 2 * count + edge.x
		indices[cursor + 1] = 2 * count + edge.y
		indices[cursor + 2] = tip
		cursor += 3

	var normals := PackedVector3Array()
	normals.resize(positions.size())
	for index in range(0, indices.size(), 3):
		var a := indices[index]
		var b := indices[index + 1]
		var c := indices[index + 2]
		var face := (positions[c] - positions[a]).cross(positions[b] - positions[a])
		normals[a] += face
		normals[b] += face
		normals[c] += face
	var input_tangents: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
	var tangent := Vector3(input_tangents[0], input_tangents[1], input_tangents[2])
	var tangents := PackedFloat32Array()
	tangents.resize(positions.size() * 4)
	for index in normals.size():
		var smooth := normals[index].normalized()
		var smoothed_tangent := tangent.slide(smooth).normalized()
		normals[index] = smooth
		tangents[index * 4] = smoothed_tangent.x
		tangents[index * 4 + 1] = smoothed_tangent.y
		tangents[index * 4 + 2] = smoothed_tangent.z
		tangents[index * 4 + 3] = input_tangents[3]
	arrays[Mesh.ARRAY_VERTEX] = positions
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TANGENT] = tangents
	arrays[Mesh.ARRAY_TEX_UV] = texcoords
	arrays[Mesh.ARRAY_INDEX] = indices
	if paint_rim:
		arrays[Mesh.ARRAY_COLOR] = colors
