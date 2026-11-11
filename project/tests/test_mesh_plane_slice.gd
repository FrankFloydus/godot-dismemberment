extends SceneTree

const TOLERANCE := 0.00002
const DEFAULT_CAP_PATH := "res://addons/godot-dismemberment/materials/slice_cap.tres"

var checks := 0
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var exterior := StandardMaterial3D.new()
	var cap := StandardMaterial3D.new()
	var recut_cap := StandardMaterial3D.new()
	var cube := _make_boxes([Vector3.ZERO], exterior)
	_check_default_cap(cube)
	_check_worker_snapshot(cube, cap)
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
	_check_nested_contours(exterior, cap, recut_cap)
	_check_localized_sever(exterior, cap, recut_cap)

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
	_check_collision_hull()
	print("MESH_PLANE_SLICE_CHECKS=%d FAILURES=%d" % [checks, failures])
	quit(1 if failures else 0)

func _check_default_cap(cube: ArrayMesh) -> void:
	var bundled := load(DEFAULT_CAP_PATH) as StandardMaterial3D
	_check(bundled != null, "the addon ships an editable default cap material")
	if bundled == null:
		return
	_check(bundled.albedo_texture != null, "the default cap has an albedo map")
	_check(bundled.normal_enabled and bundled.normal_texture != null, "the default cap uses a normal map")
	_check(bundled.roughness_texture != null, "the default cap has a roughness map")
	_check(bundled.metallic_texture != null, "the default cap has a metallic map")
	var plane := Plane(Vector3.RIGHT, 0.35)
	var halves := MeshPlaneSlice.slice_mesh(cube, plane)
	var pieces := MeshPlaneSlice.slice_mesh_pieces(cube, plane)
	var sever := MeshPlaneSlice.sever_connected_piece(cube, plane, Vector3.RIGHT)
	var instance := MeshInstance3D.new()
	instance.mesh = cube
	var posed := MeshPlaneSlice.slice_pose(instance, null, plane)
	instance.free()
	for pair: Array in [
			[halves.get("positive_mesh"), halves.get("negative_mesh")],
			pieces.get("positive_pieces", []) + pieces.get("negative_pieces", []),
			[sever.get("detached_mesh"), sever.get("retained_mesh")],
			posed.get("positive_pieces", []) + posed.get("negative_pieces", [])]:
		var matches := pair.size() == 2
		for mesh: ArrayMesh in pair:
			if mesh == null or mesh.get_surface_count() == 0:
				matches = false
				continue
			var cap := mesh.get_surface_count() - 1
			matches = (matches and mesh.surface_get_name(cap) == "Slice Cap"
				and mesh.surface_get_material(cap) == bundled)
		_check(matches, "both cut outputs use the bundled material with no override")

func _check_worker_snapshot(cube: ArrayMesh, material: Material) -> void:
	var instance := MeshInstance3D.new()
	instance.mesh = cube
	var plane := Plane(Vector3.RIGHT, 0.35)
	var synchronous := MeshPlaneSlice.slice_pose(instance, null, plane, material)
	var job := MeshPlaneSlice.capture_pose_job(instance, null, plane, 0.000001, true)
	var fitted := MeshPlaneSlice.capture_pose_job(instance, null, Plane(Vector3.RIGHT, 42.0),
		0.000001, false, PackedStringArray(), true)
	instance.free()
	if job == null:
		_check(false, "the worker captures a valid independent pose job")
		return
	_check(job.get_cut_plane() == plane, "a regular worker preserves the requested cut plane")
	_check(fitted != null and fitted.compute() and fitted.get_cut_plane().normal == Vector3.RIGHT
		and absf(fitted.get_cut_plane().d) < 1.0, "a fitted worker moves the requested plane inside the captured pose")
	_check(job.finish(material).has("error"), "a job cannot publish before its computation")
	var task := WorkerThreadPool.add_task(job.compute)
	WorkerThreadPool.wait_for_task_completion(task)
	var result := job.finish(material)
	_check(result.get("loop_count") == synchronous.get("loop_count"), "worker and synchronous cut report the same contours")
	for side: String in ["positive_pieces", "negative_pieces"]:
		var expected: Array = synchronous[side]
		var actual: Array = result.get(side, [])
		var hulls: Array = result.get(side.replace("_pieces", "_hulls"), [])
		if actual.size() != expected.size():
			_check(false, "worker and synchronous cut produce the same piece count")
			continue
		for index in expected.size():
			var worker_mesh: ArrayMesh = actual[index]
			var synchronous_mesh: ArrayMesh = expected[index]
			var same := worker_mesh.get_surface_count() == synchronous_mesh.get_surface_count()
			var points := PackedVector3Array()
			for surface in worker_mesh.get_surface_count():
				var arrays := worker_mesh.surface_get_arrays(surface)
				points.append_array(arrays[Mesh.ARRAY_VERTEX])
				same = same and arrays == synchronous_mesh.surface_get_arrays(surface) \
					and worker_mesh.surface_get_material(surface) == synchronous_mesh.surface_get_material(surface)
			_check(same, "worker snapshot publishes identical geometry and custom materials")
			_check(hulls.size() == expected.size() and hulls[index] == MeshPlaneSlice.reduce_collision_hull(points),
				"worker collision samples match the published piece")
	_check(job.finish(material).has("error") and not job.compute(), "a consumed result cannot publish or compute again")

func _check_collision_hull() -> void:
	var points := PackedVector3Array([Vector3.UP, Vector3.DOWN])
	for latitude in range(1, 12):
		var theta := PI * latitude / 12.0
		for longitude in 24:
			var phi := TAU * longitude / 24.0
			points.append(Vector3(0.8 * sin(theta) * cos(phi), cos(theta), 0.45 * sin(theta) * sin(phi)))
	var reduced := MeshPlaneSlice.reduce_collision_hull(points)
	_check(reduced.size() >= 4 and reduced.size() <= 98 and reduced.size() < points.size(),
		"a dense convex hull has bounded support point count")
	_check(reduced == MeshPlaneSlice.reduce_collision_hull(points), "hull reduction is deterministic")

	var supports_preserved := true
	for x in range(-2, 3):
		for y in range(-2, 3):
			for z in range(-2, 3):
				if maxi(absi(x), maxi(absi(y), absi(z))) != 2:
					continue
				var direction := Vector3(x, y, z)
				supports_preserved = supports_preserved and is_equal_approx(
					_maximum_projection(points, direction), _maximum_projection(reduced, direction))
	_check(supports_preserved, "reduction preserves the exact extrema in all 98 support directions")

	var tetrahedron := PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP, Vector3.BACK])
	_check(MeshPlaneSlice.reduce_collision_hull(tetrahedron) == tetrahedron, "small hulls stay unchanged")
	var coplanar := PackedVector3Array()
	for point in points:
		coplanar.append(Vector3(point.x, 0.0, point.z))
	_check(MeshPlaneSlice.reduce_collision_hull(coplanar) == coplanar, "a flat hull uses the original points")
	var invalid := points.duplicate()
	invalid.append(Vector3.INF)
	_check(MeshPlaneSlice.reduce_collision_hull(invalid) == invalid, "non-finite hull input stays unchanged")

func _maximum_projection(points: PackedVector3Array, direction: Vector3) -> float:
	var farthest := -INF
	for point in points:
		farthest = maxf(farthest, direction.dot(point))
	return farthest

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
		expected_area: float, label: String, expect_within_half := true) -> float:
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
	var expected_extent := " stays within its half-space" if expect_within_half else " retains geometry across the plane"
	_check(vertices_in_half == expect_within_half, label + expected_extent)
	_check(cap_on_plane and cap_faces_out and cap_normals_out,
		label + " cap vertices, winding and normals agree with the plane")
	_check(triangles_valid, label + " contains nondegenerate triangles")
	_check(not edge_count.is_empty() and bad_edge_count == 0,
		"%s welds exactly by position into a closed oriented mesh (%d open or mismatched edges)" %
		[label, bad_edge_count])
	_near(cap_area, expected_area, label + " cap area")
	return volume

func _check_localized_sever(exterior: Material, initial_cap: Material, sever_cap: Material) -> void:
	# A closed fork has two tines joined by a crossbar below y = 0.
	var profile := PackedVector2Array([
		Vector2(-1, -2), Vector2(3, -2), Vector2(3, -1), Vector2(0, -1),
		Vector2(0, 1), Vector2(3, 1), Vector2(3, 2), Vector2(-1, 2),
	])
	var fork := _make_prism(profile, exterior)
	var initial := _check_cut(fork, Plane(Vector3.RIGHT, -0.25), initial_cap, [exterior],
		1, 10.0, 12.5, 7.5, "initial slice of the connected fork")
	var sliced := initial.get("positive_mesh") as ArrayMesh
	if sliced == null:
		return

	# The joint plane crosses both tines. The hit lies on the outside of the left tine.
	var plane := Plane(Vector3.UP, 1.25)
	var result := MeshPlaneSlice.sever_connected_piece(sliced, plane, Vector3(1.0, 2.7, -1.5), sever_cap)
	var detached := result.get("detached_mesh") as ArrayMesh
	var retained := result.get("retained_mesh") as ArrayMesh
	_check(not result.has("error") and detached != null and retained != null and result.get("loop_count") == 1,
		"severing an already sliced mesh caps only the hit tine: %s" % result.get("error", ""))
	if detached == null or retained == null:
		return

	var detached_volume := _check_half(detached, plane, 1, sever_cap, [exterior, initial_cap],
		1.25, "detached tine")
	var retained_volume := _check_half(retained, plane, -1, sever_cap, [exterior, initial_cap],
		1.25, "retained fork", false)
	_near(detached_volume, 2.1875, "the detached piece contains only the distal hit tine")
	_near(retained_volume, 10.3125, "the retained piece keeps the crossbar and other tine")
	_near(detached_volume + retained_volume, _volume(sliced), "localized sever conserves volume")
	_check(detached.get_aabb().end.z <= -1.0 + TOLERANCE and
		retained.get_aabb().end.y >= 3.0 - TOLERANCE and retained.get_aabb().end.z >= 2.0 - TOLERANCE,
		"the untouched tine remains full length on the retained piece")
	var only_unhit_tine_crosses := true
	for surface in retained.get_surface_count():
		for point: Vector3 in retained.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]:
			if plane.distance_to(point) > TOLERANCE and point.z < 1.0 - TOLERANCE:
				only_unhit_tine_crosses = false
	_check(only_unhit_tine_crosses, "no distal geometry from the severed tine remains on the retained piece")

	var second_plane := Plane(Vector3.UP, 1.75)
	var repeat := MeshPlaneSlice.sever_connected_piece(retained, second_plane,
		Vector3(1.0, 2.7, -1.5), sever_cap)
	_check(repeat.has("error") and not repeat.has("detached_mesh") and not repeat.has("retained_mesh"),
		"a shot near the missing tine does not sever the remaining tine")
	var second_cap := StandardMaterial3D.new()
	var followup := MeshPlaneSlice.sever_connected_piece(retained, second_plane,
		Vector3(1.0, 2.7, 1.5), second_cap)
	var second_detached := followup.get("detached_mesh") as ArrayMesh
	var second_retained := followup.get("retained_mesh") as ArrayMesh
	_check(not followup.has("error") and second_detached != null and second_retained != null and
		followup.get("loop_count") == 1, "a follow-up shot can sever the untouched tine")
	if second_detached == null or second_retained == null:
		return
	_near(_check_half(second_detached, second_plane, 1, second_cap, [exterior, initial_cap], 1.25,
		"second detached tine"), 1.5625, "second detached volume")
	_near(_check_half(second_retained, second_plane, -1, second_cap, [exterior, initial_cap, sever_cap], 1.25,
		"crossbar after two local cuts"), 8.75, "second retained volume")

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

func _make_boxes(centers: Array[Vector3], material: Material, open := false,
		half_size := 1.0, inside := false) -> ArrayMesh:
	var builder := SurfaceTool.new()
	builder.begin(Mesh.PRIMITIVE_TRIANGLES)
	builder.set_material(material)
	for center in centers:
		for normal in [Vector3.RIGHT, Vector3.LEFT, Vector3.UP, Vector3.DOWN, Vector3.BACK, Vector3.FORWARD]:
			if open and normal == Vector3.RIGHT:
				continue
			var axis := Vector3.UP if absf(normal.y) < 0.5 else Vector3.RIGHT
			var u := axis * half_size
			var v: Vector3 = normal.cross(axis) * half_size
			var origin: Vector3 = center + normal * half_size
			_add_quad(builder, origin - u - v, origin - u + v, origin + u + v, origin + u - v,
				-normal if inside else normal)
	builder.index()
	return builder.commit()

func _check_nested_contours(exterior: Material, cap: Material, recut_cap: Material) -> void:
	var plane := Plane(Vector3.RIGHT, 0.25)
	var tube := _make_square_tube(exterior)
	var split := _check_cut(tube, plane, cap, [exterior], 2, 12.0, 9.0, 15.0,
		"connected square tube with a hole")
	var positive := split.get("positive_mesh") as ArrayMesh
	if positive != null:
		_check_cut(positive, Plane(Vector3.UP, 0.0), recut_cap, [exterior, cap],
			2, 1.5, 4.5, 4.5, "recut through the annular cap")

	var inner := _make_boxes([Vector3.ZERO], exterior, false, 0.5)
	tube.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, inner.surface_get_arrays(0))
	tube.surface_set_material(1, exterior)
	_check_cut(tube, plane, cap, [exterior], 3, 13.0, 9.25, 15.75, "material island inside a cut hole")

	var nested := _make_boxes([Vector3.ZERO], exterior)
	nested.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, inner.surface_get_arrays(0))
	nested.surface_set_material(1, exterior)
	_check_cut(nested, plane, cap, [exterior], 2, 5.0, 3.25, 5.75, "nested independent solid shells")
	var pieces := MeshPlaneSlice.slice_mesh_pieces(nested, plane, cap)
	_check(pieces.get("positive_pieces", []).size() == 2 and pieces.get("negative_pieces", []).size() == 2,
		"the caps of independent nested solids do not join the pieces")

	var shell_with_hole := _make_square_tube(exterior)
	var overlapping_solid := _make_boxes([Vector3.ZERO], exterior, false, 1.5)
	shell_with_hole.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, overlapping_solid.surface_get_arrays(0))
	shell_with_hole.surface_set_material(1, exterior)
	pieces = MeshPlaneSlice.slice_mesh_pieces(shell_with_hole, plane, cap)
	_check(pieces.get("positive_pieces", []).size() == 2 and pieces.get("negative_pieces", []).size() == 2,
		"the connected cavity is capped with its own shell even inside another solid outline")

	var ambiguous_cavity := _make_boxes([Vector3.ZERO], exterior, false, 0.375, true)
	nested.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, ambiguous_cavity.surface_get_arrays(0))
	var ambiguous := MeshPlaneSlice.slice_mesh(nested, plane, cap)
	_check(ambiguous.get("error") == "A cut cavity has ambiguous shell ownership." and not ambiguous.has("positive_mesh"),
		"a disconnected cavity inside overlapping solid outlines is rejected atomically")

	var multiple := _make_boxes([Vector3.ZERO], exterior, false, 2.0)
	var cavities := _make_boxes([Vector3(0, -0.75, 0), Vector3(0, 0.75, 0)], exterior, false, 0.25, true)
	multiple.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, cavities.surface_get_arrays(0))
	multiple.surface_set_material(1, exterior)
	_check_cut(multiple, Plane(Vector3.RIGHT, 0.125), cap, [exterior], 3, 15.5, 29.9375, 33.8125,
		"two cut cavities within one outline")

	var crossing := _make_boxes([Vector3.ZERO, Vector3(0, 1.25, 0.75)], exterior)
	var refused := MeshPlaneSlice.slice_mesh(crossing, plane, cap)
	_check(refused.get("error") == "The cut contours touch or cross." and not refused.has("positive_mesh"),
		"intersecting section outlines are rejected with a specific diagnostic")

func _make_square_tube(material: Material) -> ArrayMesh:
	var corners := [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]
	var builder := SurfaceTool.new()
	builder.begin(Mesh.PRIMITIVE_TRIANGLES)
	builder.set_material(material)
	for i in corners.size():
		var a: Vector2 = corners[i]
		var b: Vector2 = corners[(i + 1) % corners.size()]
		var edge := b - a
		var normal := Vector3(0, edge.y, -edge.x).normalized()
		for radius in [1.0, 2.0]:
			_add_quad(builder, _prism_vertex(-1.0, a * radius), _prism_vertex(-1.0, b * radius),
				_prism_vertex(1.0, b * radius), _prism_vertex(1.0, a * radius),
				normal if radius == 2.0 else -normal)
		for x in [-1.0, 1.0]:
			_add_quad(builder, _prism_vertex(x, a * 2.0), _prism_vertex(x, b * 2.0),
				_prism_vertex(x, b), _prism_vertex(x, a), Vector3(x, 0, 0))
	builder.index()
	return builder.commit()

func _make_concave_prism(material: Material) -> ArrayMesh:
	# The cross-section is a 3 by 3 square with a 2 by 2 corner removed.
	var polygon := PackedVector2Array([
		Vector2(-1.5, -1.5), Vector2(1.5, -1.5), Vector2(1.5, -0.5),
		Vector2(-0.5, -0.5), Vector2(-0.5, 1.5), Vector2(-1.5, 1.5),
	])
	return _make_prism(polygon, material)

func _make_prism(polygon: PackedVector2Array, material: Material) -> ArrayMesh:
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
