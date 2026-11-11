extends SceneTree

const TOLERANCE := 0.00002

var checks := 0
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var exterior := StandardMaterial3D.new()
	var cap := StandardMaterial3D.new()
	var recut_cap := StandardMaterial3D.new()
	var cube := _make_boxes([Vector3.ZERO], exterior)
	var original_arrays := cube.surface_get_arrays(0)
	var offset := _check_cut(cube, Plane(Vector3.RIGHT, 0.35), cap, [exterior],
		1, 4.0, 2.6, 5.4, "offset cube with collinear seam points")

	var diagonal := Vector3(1, 1, 0).normalized()
	var diagonal_length := 2.0 - 0.25 * sqrt(2.0)
	var angled_volume := diagonal_length * diagonal_length
	_check_cut(cube, Plane(diagonal, 0.25), cap, [exterior],
		1, 2.0 * sqrt(2.0) * diagonal_length, angled_volume, 8.0 - angled_volume,
		"angled offset cube")
	_check_cut(cube, Plane(diagonal, 0.0), cap, [exterior],
		1, 4.0 * sqrt(2.0), 4.0, 4.0, "cube cut through existing vertices and edges")

	var positive := offset.get("positive_mesh") as ArrayMesh
	if positive != null:
		_check_cut(positive, Plane(Vector3.UP, 0.1), recut_cap, [exterior, cap],
			1, 1.3, 1.17, 1.43, "recut through the previous cap")

	var two_boxes := _make_boxes([Vector3(0, -2.5, 0), Vector3(0, 2.5, 0)], exterior)
	_check_cut(two_boxes, Plane(Vector3.RIGHT, 0.3), cap, [exterior],
		2, 8.0, 5.6, 10.4, "two disconnected cap loops")
	_check_connected_pieces(two_boxes, exterior, cap)

	var concave := _make_concave_prism(exterior)
	_check_cut(concave, Plane(Vector3.RIGHT, -0.2), cap, [exterior],
		1, 5.0, 6.0, 4.0, "concave cap loop")

	_check_rejected(_make_boxes([Vector3.ZERO], exterior, true), Plane(Vector3.RIGHT, 0.35),
		"open source")
	_check_rejected(cube, Plane(Vector3.RIGHT, 3.0), "plane outside the source")
	_check_rejected(cube, Plane(Vector3.RIGHT, 1.0), "tangent plane")
	_check_rejected(_make_boxes([Vector3.ZERO, Vector3(1, 3.5, 0)], exterior),
		Plane(Vector3.RIGHT, 1.0), "cut with a coplanar input face")
	_check_rejected(cube, Plane(Vector3.ZERO, 0.0), "zero plane normal")
	_check_rejected(cube, Plane(Vector3(NAN, 0, 0), 0.0), "non-finite plane")
	_check_rejected(null, Plane(Vector3.RIGHT, 0.35), "null source")
	_check(cube.get_surface_count() == 1 and cube.surface_get_material(0) == exterior and
		cube.surface_get_arrays(0) == original_arrays, "slices leave the input mesh untouched")
	print("MESH_PLANE_SLICE_CHECKS=%d FAILURES=%d" % [checks, failures])
	quit(1 if failures else 0)

func _check_connected_pieces(two_boxes: ArrayMesh, exterior: Material, cap: Material) -> void:
	var untouched_material := StandardMaterial3D.new()
	var uncut := _make_boxes([Vector3(3.5, 0, 0)], untouched_material)
	var source := two_boxes.duplicate() as ArrayMesh
	source.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, uncut.surface_get_arrays(0))
	source.surface_set_material(1, untouched_material)
	var plane := Plane(Vector3.RIGHT, 0.3)
	var result := MeshPlaneSlice.slice_mesh_pieces(source, plane, cap)
	_check(not result.has("error") and result.get("loop_count") == 2,
		"piece output retains both cut contours")
	var positive: Array = result.get("positive_pieces", [])
	var negative: Array = result.get("negative_pieces", [])
	_check(positive.is_typed() and negative.is_typed() and
		positive.get_typed_class_name() == &"ArrayMesh" and negative.get_typed_class_name() == &"ArrayMesh",
		"both result arrays are typed as ArrayMesh")
	_check(positive.size() == 3 and negative.size() == 2,
		"each connected section has a separate resource, including the uncut box")
	var total_volume := 0.0
	for side in [1, -1]:
		var pieces: Array = positive if side == 1 else negative
		for piece: ArrayMesh in pieces:
			if piece.get_surface_count() == 1:
				_check(side == 1 and piece.surface_get_material(0) == untouched_material
					and piece.get_aabb().is_equal_approx(uncut.get_aabb()), "the uncut component stays intact")
				total_volume += _volume(piece)
			else:
				_check(piece.get_aabb().size.y < 2.01, "a piece does not bridge the gap between boxes")
				total_volume += _check_half(piece, plane, side, cap, [exterior], 4.0, "separate box section")
	_near(total_volume, _volume(source), "all connected pieces conserve volume")

	var instance := MeshInstance3D.new()
	instance.mesh = source
	var override := StandardMaterial3D.new()
	instance.material_override = override
	var posed := MeshPlaneSlice.slice_pose(instance, null, plane, cap)
	var posed_positive: Array = posed.get("positive_pieces", [])
	var posed_negative: Array = posed.get("negative_pieces", [])
	_check(posed_positive.size() == positive.size() and posed_negative.size() == negative.size() and
		posed.get("loop_count") == 2, "the direct pose API emits the same connected sections")
	for piece: ArrayMesh in posed_positive + posed_negative:
		_check(piece.surface_get_material(0) == override, "the pose API keeps active instance material")
	instance.free()

func _check_cut(source: ArrayMesh, plane: Plane, cap: Material, exterior: Array[Material],
		expected_loops: int, expected_area: float, expected_positive: float, expected_negative: float,
		label: String) -> Dictionary:
	var result := MeshPlaneSlice.slice_mesh(source, plane, cap)
	_check(not result.has("error"), "%s succeeds: %s" % [label, result.get("error", "")])
	var positive := result.get("positive_mesh") as ArrayMesh
	var negative := result.get("negative_mesh") as ArrayMesh
	_check(positive != null and negative != null and positive != negative and positive != source and
		negative != source, label + " returns two independent ArrayMesh resources")
	if positive == null or negative == null:
		return result
	_check(result.get("loop_count") == expected_loops, "%s has %d cap loops" % [label, expected_loops])
	var positive_volume := _check_half(positive, plane, 1, cap, exterior, expected_area, label + " positive")
	var negative_volume := _check_half(negative, plane, -1, cap, exterior, expected_area, label + " negative")
	_near(positive_volume, expected_positive, label + " positive signed volume")
	_near(negative_volume, expected_negative, label + " negative signed volume")
	_near(positive_volume + negative_volume, _volume(source), label + " conserves signed volume")
	return result

func _check_half(mesh: ArrayMesh, plane: Plane, side: int, cap: Material, exterior: Array[Material],
		expected_area: float, label: String) -> float:
	var vertices := {}
	var edge_count := {}
	var edge_balance := {}
	var exterior_found := {}
	var vertices_in_half := true
	var cap_on_plane := true
	var cap_faces_out := true
	var cap_normals_out := true
	var triangles_valid := true
	var cap_area := 0.0
	var volume := 0.0
	var surfaces := mesh.get_surface_count()
	_check(surfaces > 1 and mesh.surface_get_material(surfaces - 1) == cap and
		mesh.surface_get_name(surfaces - 1) == "Slice Cap", label + " names and assigns the final cap surface")
	var cap_normal := -plane.normal * side

	for surface in surfaces:
		var is_cap := surface == surfaces - 1
		if not is_cap:
			exterior_found[mesh.surface_get_material(surface)] = true
		var arrays := mesh.surface_get_arrays(surface)
		var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices := _triangle_indices(arrays)
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] is PackedVector3Array else PackedVector3Array()
		triangles_valid = triangles_valid and mesh.surface_get_primitive_type(surface) == Mesh.PRIMITIVE_TRIANGLES
		triangles_valid = triangles_valid and indices.size() % 3 == 0
		for position in positions:
			vertices_in_half = vertices_in_half and side * plane.distance_to(position) >= -TOLERANCE
			if is_cap:
				cap_on_plane = cap_on_plane and absf(plane.distance_to(position)) < TOLERANCE
		if is_cap:
			cap_normals_out = cap_normals_out and normals.size() == positions.size()
			for normal in normals:
				cap_normals_out = cap_normals_out and normal.dot(cap_normal) > 0.999

		for offset in range(0, indices.size() - 2, 3):
			var a := positions[indices[offset]]
			var b := positions[indices[offset + 1]]
			var c := positions[indices[offset + 2]]
			var area_vector := (c - a).cross(b - a)
			triangles_valid = triangles_valid and area_vector.length_squared() > 0.000000000001
			volume += a.dot(c.cross(b)) / 6.0
			if is_cap:
				cap_area += area_vector.length() * 0.5
				cap_faces_out = cap_faces_out and area_vector.dot(cap_normal) > 0.0
			var triangle: Array[Vector3] = [a, b, c]
			for corner in 3:
				var start := _exact_vertex_id(vertices, triangle[corner])
				var finish := _exact_vertex_id(vertices, triangle[(corner + 1) % 3])
				var edge := Vector2i(mini(start, finish), maxi(start, finish))
				edge_count[edge] = int(edge_count.get(edge, 0)) + 1
				edge_balance[edge] = int(edge_balance.get(edge, 0)) + (1 if start < finish else -1)

	var bad_edge_count := 0
	for edge in edge_count:
		if edge_count[edge] != 2 or edge_balance[edge] != 0:
			bad_edge_count += 1
	var exterior_preserved := exterior_found.size() == exterior.size()
	for material in exterior:
		exterior_preserved = exterior_preserved and exterior_found.has(material)
	_check(exterior_preserved, label + " preserves exterior materials")
	_check(vertices_in_half, label + " contains no vertices on the wrong side")
	_check(cap_on_plane and cap_faces_out and cap_normals_out,
		label + " cap vertices, winding and normals agree with the plane")
	_check(triangles_valid, label + " contains nondegenerate triangles")
	_check(not edge_count.is_empty() and bad_edge_count == 0,
		"%s welds exactly by position into a closed oriented mesh (%d open or mismatched edges)" %
		[label, bad_edge_count])
	_near(cap_area, expected_area, label + " cap area")
	return volume

func _check_rejected(mesh: ArrayMesh, plane: Plane, label: String) -> void:
	var result := MeshPlaneSlice.slice_mesh(mesh, plane)
	_check(not str(result.get("error", "")).is_empty() and not result.has("positive_mesh") and
		not result.has("negative_mesh"), label + " safely returns an error without partial output")

func _triangle_indices(arrays: Array) -> PackedInt32Array:
	if arrays[Mesh.ARRAY_INDEX] is PackedInt32Array and not arrays[Mesh.ARRAY_INDEX].is_empty():
		return arrays[Mesh.ARRAY_INDEX]
	var indices := PackedInt32Array()
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	indices.resize(positions.size())
	for index in indices.size():
		indices[index] = index
	return indices

func _exact_vertex_id(vertices: Dictionary, vertex: Vector3) -> int:
	if not vertices.has(vertex):
		vertices[vertex] = vertices.size()
	return vertices[vertex]

func _volume(mesh: ArrayMesh) -> float:
	var total := 0.0
	for surface in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface)
		var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices := _triangle_indices(arrays)
		for offset in range(0, indices.size(), 3):
			total += positions[indices[offset]].dot(
				positions[indices[offset + 2]].cross(positions[indices[offset + 1]])) / 6.0
	return total

func _make_boxes(centers: Array[Vector3], material: Material, open := false) -> ArrayMesh:
	var builder := SurfaceTool.new()
	builder.begin(Mesh.PRIMITIVE_TRIANGLES)
	builder.set_material(material)
	for center in centers:
		for normal in [Vector3.RIGHT, Vector3.LEFT, Vector3.UP, Vector3.DOWN, Vector3.BACK, Vector3.FORWARD]:
			if open and normal == Vector3.RIGHT:
				continue
			var u: Vector3 = Vector3.UP if absf(normal.y) < 0.5 else Vector3.RIGHT
			var v: Vector3 = normal.cross(u)
			var origin: Vector3 = center + normal
			_add_quad(builder, origin - u - v, origin - u + v, origin + u + v, origin + u - v, normal)
	builder.index()
	return builder.commit()

func _make_concave_prism(material: Material) -> ArrayMesh:
	# The cross-section is a 3 by 3 square with a 2 by 2 corner removed.
	var polygon := PackedVector2Array([
		Vector2(-1.5, -1.5), Vector2(1.5, -1.5), Vector2(1.5, -0.5),
		Vector2(-0.5, -0.5), Vector2(-0.5, 1.5), Vector2(-1.5, 1.5),
	])
	var builder := SurfaceTool.new()
	builder.begin(Mesh.PRIMITIVE_TRIANGLES)
	builder.set_material(material)
	var ends := Geometry2D.triangulate_polygon(polygon)
	for x in [-1.0, 1.0]:
		var normal := Vector3(x, 0, 0)
		for index in range(0, ends.size(), 3):
			_add_triangle(builder, _prism_vertex(x, polygon[ends[index]]),
				_prism_vertex(x, polygon[ends[index + 1]]), _prism_vertex(x, polygon[ends[index + 2]]), normal)
	for index in polygon.size():
		var a := polygon[index]
		var b := polygon[(index + 1) % polygon.size()]
		var edge := b - a
		var normal := Vector3(0, edge.y, -edge.x).normalized()
		_add_quad(builder, _prism_vertex(-1.0, a), _prism_vertex(-1.0, b),
			_prism_vertex(1.0, b), _prism_vertex(1.0, a), normal)
	builder.index()
	return builder.commit()

func _prism_vertex(x: float, point: Vector2) -> Vector3:
	return Vector3(x, point.x, point.y)

func _add_quad(builder: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, normal: Vector3) -> void:
	_add_triangle(builder, a, b, c, normal)
	_add_triangle(builder, a, c, d, normal)

func _add_triangle(builder: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, normal: Vector3) -> void:
	# Godot uses clockwise triangle winding as viewed from the visible side.
	if (c - a).cross(b - a).dot(normal) < 0.0:
		var swap := b
		b = c
		c = swap
	for point in [a, b, c]:
		builder.set_normal(normal)
		builder.add_vertex(point)

func _near(actual: float, expected: float, label: String) -> void:
	_check(absf(actual - expected) < TOLERANCE, "%s is %.8f (expected %.8f)" % [label, actual, expected])

func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(label)
