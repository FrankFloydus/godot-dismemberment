extends SceneTree

const Fixture = preload("res://tests/rig_fixture.gd")
var checks := 0
var failures := 0

func _initialize() -> void:
	if "--custom-shader" in OS.get_cmdline_user_args():
		_run_custom_shader.call_deferred()
	else:
		_run.call_deferred()

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("GORE AUDIT: " + message)

func image_texture(color: Color) -> ImageTexture:
	var image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	image.fill(color)
	return ImageTexture.create_from_image(image)

func frames(count := 3) -> void:
	for _frame in count:
		await process_frame

func add_garment(value: Dictionary) -> MeshInstance3D:
	var garment := MeshInstance3D.new()
	garment.name = "Garment"
	garment.mesh = value.mesh.mesh
	garment.skin = value.mesh.skin
	garment.skeleton = value.mesh.skeleton
	value.actor.add_child(garment)
	value.component.support_attached_child_meshes = true
	return garment

func configure_animation_test(value: Dictionary) -> void:
	value.component.enable_blood_particles = false
	value.component.enable_blood_pool_decal = false
	# Keep the first-paint fade in progress even on a slow test machine.
	value.component.blood_animation_time = 20.0

func _run_modular_animation() -> void:
	var value: Dictionary = Fixture.make_rig("GoreComponent")
	configure_animation_test(value)
	var garment := add_garment(value)
	root.add_child(value.actor)
	await frames()
	check(value.component.get_all_meshes().has(garment), "modular garment is associated with the source rig")
	value.component.apply_blood(&"lower")
	var garment_material := garment.get_active_material(0) as ShaderMaterial
	check(is_equal_approx(garment_material.get_shader_parameter("blood_animation"), 1.0), "garment paint starts fully visible")
	await frames()
	var body_material: ShaderMaterial = value.mesh.get_active_material(0)
	var body_animation: float = body_material.get_shader_parameter("blood_animation")
	check(body_animation > 0.0 and body_animation < 1.0, "main mesh runs the first-paint fade")
	check(is_equal_approx(garment_material.get_shader_parameter("blood_animation"), 1.0), "main mesh fade leaves garment fully painted")
	value.actor.queue_free()
	await frames()

func _run_custom_shader() -> void:
	var shader := Shader.new()
	shader.code = """
		shader_type spatial;
		uniform float blood_animation = 0.0;
		uniform vec4 base_color : source_color = vec4(1.0);
		void fragment() {
			ALBEDO = mix(base_color.rgb, vec3(0.05, 0.0, 0.0), COLOR.b * blood_animation);
		}
	"""
	var shared := ShaderMaterial.new()
	shared.shader = shader
	shared.set_shader_parameter("blood_animation", 0.375)
	shared.set_shader_parameter("base_color", Color(0.25, 0.5, 0.75))
	var value: Dictionary = Fixture.make_rig("GoreComponent")
	configure_animation_test(value)
	value.component.auto_apply_blood_material = false
	value.component.geometry_mode = 0
	value.mesh.material_override = shared
	var garment := add_garment(value)
	garment.set_surface_override_material(0, shared)
	root.add_child(value.actor)
	await frames()
	var body_material: ShaderMaterial = value.mesh.material_override
	var garment_material: ShaderMaterial = garment.get_surface_override_material(0)
	check(body_material != shared and garment_material != shared and body_material != garment_material,
		"custom global and surface materials get independent animation values")
	check(body_material.shader == shader and garment_material.shader == shader,
		"custom shader is retained on both meshes")
	check(body_material.get_shader_parameter("base_color") == shared.get_shader_parameter("base_color"),
		"non-animation custom uniforms are preserved")
	check(is_equal_approx(shared.get_shader_parameter("blood_animation"), 0.375),
		"initialization preserves shared custom material")
	value.component.dismember_limb(&"lower")
	await frames()
	var body_animation: float = body_material.get_shader_parameter("blood_animation")
	check(body_animation > 0.0 and body_animation < 1.0, "custom body material receives the main fade")
	check(is_equal_approx(garment_material.get_shader_parameter("blood_animation"), 1.0),
		"custom garment material stays fully painted")
	var limb: DismemberedLimb = value.component.get_dismembered_limb_by_name(&"lower")
	check(limb != null and not limb.get_meshes().is_empty(), "detached limb retains its meshes")
	if limb != null and not limb.get_meshes().is_empty():
		var detached_mesh: MeshInstance3D = limb.get_meshes()[0]
		var detached_material: ShaderMaterial = detached_mesh.get_active_material(0)
		check(detached_material != body_material and detached_material.shader == shader,
			"detached material has separate state and keeps the custom shader")
		check(is_equal_approx(detached_material.get_shader_parameter("blood_animation"), 1.0),
			"custom detached wound is immediately visible")
	value.component.reset_all_limbs()
	await frames()
	var restored_garment := garment.get_active_material(0) as ShaderMaterial
	check(restored_garment != null and restored_garment.shader == shader
		and is_equal_approx(value.mesh.material_override.get_shader_parameter("blood_animation"), 0.0)
		and is_equal_approx(restored_garment.get_shader_parameter("blood_animation"), 0.0),
		"reset clears only the source rig's animation values")
	check(is_equal_approx(shared.get_shader_parameter("blood_animation"), 0.375),
		"cut and reset preserve the shared custom material's animation value")
	value.actor.queue_free()
	await frames()
	print("Custom blood material checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _run() -> void:
	var value: Dictionary = Fixture.make_rig("GoreComponent")
	value.component.geometry_mode = 0
	value.component.enable_blood_particles = false
	value.component.enable_blood_pool_decal = false
	value.component.blood_paint_radius = 1.2
	value.component.blood_paint_limb_radius = 0.3
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.65, 0.6, 0.55)
	material.albedo_texture = image_texture(Color(0.5, 0.6, 0.7))
	material.roughness = 0.7
	material.roughness_texture = image_texture(Color(0.2, 0.8, 0.4))
	material.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
	material.metallic = 0.3
	material.metallic_specular = 0.8
	material.metallic_texture = material.roughness_texture
	material.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_BLUE
	material.normal_enabled = true
	material.normal_scale = 0.7
	material.normal_texture = image_texture(Color(0.5, 0.5, 1))
	material.ao_enabled = true
	material.ao_texture = image_texture(Color(0.8, 0.6, 0.4))
	material.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	material.ao_light_affect = 0.4
	material.uv1_scale = Vector3(2, 3, 1)
	material.uv1_offset = Vector3(0.1, 0.2, 0)
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	value.mesh.material_override = material
	root.add_child(value.actor)
	await frames()
	var initial_colors: PackedColorArray = value.mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	check(initial_colors[0].b == 0.0 and initial_colors[8].b == 0.0, "initialization clears selected blue channel on whole body")
	check(absf(initial_colors[0].r - 0.2) < 0.01 and absf(initial_colors[0].a - 0.9) < 0.01, "initialization preserves other vertex channels")
	var converted: ShaderMaterial = value.mesh.material_override
	check(converted != null, "global StandardMaterial override converts in its active slot")
	if converted != null:
		check(converted.get_shader_parameter("base_texture") == material.albedo_texture, "preserves albedo texture")
		check(converted.get_shader_parameter("normal_texture") == material.normal_texture and converted.get_shader_parameter("use_normal_texture"), "preserves enabled normal map")
		check(is_equal_approx(converted.get_shader_parameter("normal_scale"), 0.7), "preserves normal strength")
		check(is_equal_approx(converted.get_shader_parameter("metallic"), 0.3) and is_equal_approx(converted.get_shader_parameter("specular"), 0.8), "preserves metallic/specular factors")
		check(converted.get_shader_parameter("roughness_texture") == material.roughness_texture and converted.get_shader_parameter("roughness_texture_channel") == 1, "preserves packed roughness map channel")
		check(converted.get_shader_parameter("metallic_texture") == material.metallic_texture and converted.get_shader_parameter("metallic_texture_channel") == 2, "preserves packed metallic map channel")
		check(converted.get_shader_parameter("ao_texture") == material.ao_texture and converted.get_shader_parameter("use_ao_texture"), "preserves ambient occlusion map")
		check(converted.get_shader_parameter("uv1_scale") == material.uv1_scale and converted.get_shader_parameter("uv1_offset") == material.uv1_offset, "preserves base material UV transform")
		check(converted.get_shader_parameter("cull_mode") == 2, "preserves culling mode")
		check(is_equal_approx(converted.get_shader_parameter("blood_animation"), 0.0), "clean body starts with zero blood animation")
	# The posed lower bone is far from its bind-space location. World-cut paint
	# applied directly to these rest vertices misses the correct wound entirely.
	value.skeleton.set_bone_pose_rotation(2, Quaternion(Vector3.FORWARD, PI / 2))
	await frames()
	value.component.dismember_limb(&"lower")
	await frames()
	var limb: DismemberedLimb = value.component.get_dismembered_limb_by_name(&"lower")
	check(limb != null, "animated limb detaches")
	if limb != null and limb.get_meshes().size() > 0:
		var detached: MeshInstance3D = limb.get_meshes()[0]
		var colors: PackedColorArray = detached.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
		check(colors[8].b > 0.2, "skinned detached wound uses rest/bind location despite posed rotation")
		check(colors[4].b < 0.001, "detached limb does not inherit the main body's larger paint radius")
		var detached_material: ShaderMaterial = detached.material_override
		check(detached_material != converted, "detached global material is independent of source uniforms")
		check(detached_material != null and is_equal_approx(detached_material.get_shader_parameter("blood_animation"), 1.0), "detached paint becomes immediately visible")
		var preserved_before: PackedColorArray = colors.duplicate()
		value.component.remove_blood_from_static_mesh(detached)
		# Moving the detached world frame must not move its skin reference wound.
		limb.global_position += Vector3(10, 0, 0)
		value.component.apply_blood_to_mesh(detached, &"lower", 0.3, 0.2)
		colors = detached.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
		check(absf(colors[8].b - preserved_before[8].b) < 0.01, "detached reference paint remains stable after world translation")
	value.component.reset_all_limbs()
	await frames()
	var reset_colors: PackedColorArray = value.mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	check(reset_colors[8].b < 0.001, "reset clears painted blue channel")
	check(is_equal_approx(value.mesh.material_override.get_shader_parameter("blood_animation"), 0.0), "reset clears animation uniform")
	value.actor.queue_free()
	await frames()
	await _run_modular_animation()
	print("Gore source audit checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
