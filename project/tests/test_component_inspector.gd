extends SceneTree
## Native property metadata controls the Inspector without changing scene storage.

const POOL_FIELDS := [
	"blood_pool_scale", "blood_decal_lifetime", "allowed_surface_types_for_blood_decals",
	"override_blood_decal", "blood_decal", "override_blood_decal_texture",
	"blood_decal_texture", "use_world_space_tiling", "blood_decal_tile_size",
]
const PAINT_FIELDS := [
	"blood_paint_radius", "blood_paint_limb_radius", "blood_paint_falloff",
	"blood_vertex_channel", "blood_animation_time", "auto_apply_blood_material",
]
const LEGACY_PAINT_FIELDS := ["blood_paint_scale", "blood_animation_primitive_index"]

var checks := 0
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("COMPONENT_INSPECTOR: " + message)

func _check_visibility(component: Node, shown: Array, hidden: Array, context: String) -> void:
	var usage_by_property := {}
	for property in component.get_property_list():
		usage_by_property[property.name] = int(property.usage)
	for property in shown + hidden:
		var usage: int = usage_by_property.get(property, 0)
		var expected_visible := shown.has(property)
		_expect((usage & PROPERTY_USAGE_STORAGE) != 0 and
			((usage & PROPERTY_USAGE_EDITOR) != 0) == expected_visible,
			"%s: %s is stored and %s" % [context, property, "visible" if expected_visible else "hidden"])

func _change(component: Node, property: StringName, value: Variant) -> void:
	var refreshes := [0]
	var on_refresh := func() -> void: refreshes[0] += 1
	component.property_list_changed.connect(on_refresh)
	component.set(property, value)
	component.property_list_changed.disconnect(on_refresh)
	_expect(refreshes[0] > 0, "%s: changing %s refreshes the Inspector" % [component.get_class(), property])

func _check_base(component: DismembermentComponent) -> void:
	var label := component.get_class()
	_check_visibility(component, ["mesh_path", "override_source_mesh", "collapse_scale", "geometry_mode",
		"limb_rigid_fallback_enabled", "network_enabled"],
		["source_mesh_component", "update_mesh_bounds", "weight_threshold", "limb_mass", "owning_peer_id"],
		label + " defaults")
	_change(component, &"override_source_mesh", true)
	_check_visibility(component, ["source_mesh_component"], [], label + " name override")
	_change(component, &"mesh_path", NodePath("../SkinMesh"))
	_check_visibility(component, ["mesh_path"], ["override_source_mesh", "source_mesh_component"],
		label + " explicit mesh path")
	_change(component, &"mesh_path", NodePath())
	_check_visibility(component, ["override_source_mesh", "source_mesh_component"], [],
		label + " cleared mesh path")

	_change(component, &"geometry_mode", DismembermentComponent.TRIANGLE_PARTITION)
	_check_visibility(component, ["update_mesh_bounds", "weight_threshold"], ["collapse_scale", "limb_mass"],
		label + " triangle partition")
	_change(component, &"limb_rigid_fallback_enabled", true)
	_change(component, &"geometry_mode", DismembermentComponent.BONE_COLLAPSE)
	_check_visibility(component, ["collapse_scale", "weight_threshold", "limb_mass"], ["update_mesh_bounds"],
		label + " bone collapse with rigid fallback")
	_change(component, &"limb_rigid_fallback_enabled", false)
	_check_visibility(component, ["collapse_scale"], ["weight_threshold", "limb_mass"],
		label + " bone collapse without rigid fallback")

	_change(component, &"network_enabled", true)
	_check_visibility(component, ["owning_peer_id"], [], label + " networking on")
	_change(component, &"network_enabled", false)
	_check_visibility(component, ["network_enabled"], ["owning_peer_id"], label + " networking off")

func _check_gore(gore: GoreComponent) -> void:
	_check_visibility(gore, [
		"enable_blood_pool_decal", "blood_pool_scale", "blood_decal_lifetime",
		"allowed_surface_types_for_blood_decals", "override_blood_decal",
		"override_blood_decal_texture", "use_world_space_tiling", "blood_decal_tile_size",
		"enable_blood_particles", "blood_particle_scale", "override_blood_particles",
		"enable_blood_skin_painting",
	] + PAINT_FIELDS, ["blood_decal", "blood_decal_texture", "fx_blood_burst"] + LEGACY_PAINT_FIELDS,
		"GoreComponent defaults")

	_change(gore, &"override_blood_decal_texture", true)
	_check_visibility(gore, ["blood_decal_texture"], [], "custom decal texture")
	_change(gore, &"override_blood_decal", true)
	_check_visibility(gore, ["blood_decal", "override_blood_decal_texture", "blood_decal_texture",
		"blood_decal_tile_size"], [], "empty material override still uses the default material")
	_change(gore, &"blood_decal", StandardMaterial3D.new())
	_check_visibility(gore, ["blood_decal", "use_world_space_tiling"],
		["override_blood_decal_texture", "blood_decal_texture", "blood_decal_tile_size"],
		"custom material uses its own texture and tiling")
	_change(gore, &"blood_decal", null)
	_check_visibility(gore, ["override_blood_decal_texture", "blood_decal_texture", "blood_decal_tile_size"],
		[], "clearing custom material restores the default material settings")
	_change(gore, &"use_world_space_tiling", false)
	_check_visibility(gore, ["use_world_space_tiling"], ["blood_decal_tile_size"], "local pool coordinates")
	_change(gore, &"enable_blood_pool_decal", false)
	_check_visibility(gore, ["enable_blood_pool_decal"], POOL_FIELDS, "automatic pools off")

	_change(gore, &"override_blood_particles", true)
	_check_visibility(gore, ["fx_blood_burst"], [], "custom particle scene")
	_change(gore, &"enable_blood_particles", false)
	_check_visibility(gore, ["enable_blood_particles"], [
		"override_blood_particles", "blood_particle_scale", "fx_blood_burst",
	], "automatic particles off")

	_change(gore, &"enable_blood_skin_painting", false)
	_check_visibility(gore, ["enable_blood_skin_painting"], PAINT_FIELDS + LEGACY_PAINT_FIELDS,
		"automatic skin painting off")
	_change(gore, &"enable_blood_skin_painting", true)
	_check_visibility(gore, PAINT_FIELDS, LEGACY_PAINT_FIELDS, "automatic skin painting restored")

func _check_scene_round_trip(gore: GoreComponent) -> void:
	# This resource stays stored even when a custom material hides its field.
	var texture := GradientTexture2D.new()
	texture.resource_name = "Saved pool texture"
	gore.enable_blood_pool_decal = true
	gore.override_blood_decal_texture = true
	gore.blood_decal_texture = texture
	gore.override_blood_decal = true
	gore.blood_decal = StandardMaterial3D.new()
	gore.enable_blood_particles = false
	gore.blood_particle_scale = 2.5
	gore.enable_blood_skin_painting = false
	gore.blood_paint_radius = 1.75
	gore.blood_paint_scale = 3.0
	gore.owning_peer_id = 42
	gore.network_enabled = false
	gore.override_source_mesh = true
	gore.source_mesh_component = "OldBody"
	gore.mesh_path = NodePath("../SkinMesh")

	var scene := PackedScene.new()
	var result := scene.pack(gore)
	_expect(result == OK, "native node can be packed with hidden properties")
	if result != OK:
		return
	var restored := scene.instantiate() as GoreComponent
	_expect(restored != null, "packed scene restores a native GoreComponent")
	if restored == null:
		return
	_check_visibility(restored, [], ["blood_decal_texture", "blood_particle_scale", "blood_paint_radius",
		"blood_paint_scale", "owning_peer_id", "source_mesh_component"], "packed scene visibility")
	_expect(restored.blood_decal_texture != null and
		restored.blood_decal_texture.resource_name == texture.resource_name, "hidden texture survives scene packing")
	_expect(is_equal_approx(restored.blood_particle_scale, 2.5)
		and is_equal_approx(restored.blood_paint_radius, 1.75), "hidden effect values survive scene packing")
	_expect(is_equal_approx(restored.blood_paint_scale, 3.0), "legacy script-only value survives scene packing")
	_expect(restored.owning_peer_id == 42 and restored.source_mesh_component == "OldBody",
		"hidden base properties survive scene packing")
	restored.free()

func _run() -> void:
	var base := DismembermentComponent.new()
	_check_base(base)
	base.free()

	var gore := GoreComponent.new()
	_check_base(gore)
	_check_gore(gore)
	_check_scene_round_trip(gore)
	gore.free()

	print("COMPONENT_INSPECTOR_CHECKS=%d FAILURES=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
