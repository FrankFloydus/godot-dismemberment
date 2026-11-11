#include "gore_component.h"
#include "dismembered_limb.h"
#include "mesh_partition.h"

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/base_material3d.hpp>
#include <godot_cpp/classes/cpu_particles3d.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/physics_direct_space_state3d.hpp>
#include <godot_cpp/classes/physics_ray_query_parameters3d.hpp>
#include <godot_cpp/classes/quad_mesh.hpp>
#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/scene_tree.hpp>
#include <godot_cpp/classes/shader.hpp>
#include <godot_cpp/classes/shader_material.hpp>
#include <godot_cpp/classes/skeleton3d.hpp>
#include <godot_cpp/classes/skin.hpp>
#include <godot_cpp/classes/standard_material3d.hpp>
#include <godot_cpp/classes/timer.hpp>
#include <godot_cpp/classes/world3d.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <algorithm>

namespace godot {

namespace {

Vector3 reference_bone_in_mesh(MeshInstance3D *mesh, Skeleton3D *skeleton, int bone) {
    const Ref<Skin> skin = mesh->get_skin();
    if (skin.is_valid()) {
        int fallback_bind = -1;
        int fallback_bone = -1;
        for (int bind = 0; bind < skin->get_bind_count(); ++bind) {
            const StringName name = skin->get_bind_name(bind);
            const int bound_bone = name == StringName() ? skin->get_bind_bone(bind) : skeleton->find_bone(name);
            if (bound_bone < 0 || bound_bone >= skeleton->get_bone_count()) continue;
            // Inverse bind maps the bind bone origin directly into mesh rest
            // coordinates. This remains correct after a detached mesh moves.
            if (bound_bone == bone) return skin->get_bind_pose(bind).affine_inverse().origin;
            if (fallback_bind < 0) { fallback_bind = bind; fallback_bone = bound_bone; }
        }
        // Sparse skins need not contain the severed parent as a bind. Recover
        // mesh-from-skeleton rest space from any valid bind in that skin.
        if (fallback_bind >= 0) {
            const Transform3D mesh_from_skeleton = skin->get_bind_pose(fallback_bind).affine_inverse() *
                    skeleton->get_bone_global_rest(fallback_bone).affine_inverse();
            return mesh_from_skeleton.xform(skeleton->get_bone_global_rest(bone).origin);
        }
    }
    return mesh->get_global_transform().affine_inverse().xform(
            skeleton->get_global_transform().xform(skeleton->get_bone_global_rest(bone).origin));
}

bool has_skin_weights(MeshInstance3D *mesh) {
    if (!mesh || mesh->get_skin().is_null()) return false;
    const Ref<Mesh> resource = mesh->get_mesh();
    if (resource.is_null()) return false;
    const int surface_count = resource->get_surface_count();
    const Ref<ArrayMesh> array_mesh = resource;
    if (array_mesh.is_valid()) {
        for (int surface = 0; surface < surface_count; ++surface) {
            if (array_mesh->surface_get_format(surface) & Mesh::ARRAY_FORMAT_BONES) return true;
        }
        return false;
    }
    for (int surface = 0; surface < surface_count; ++surface) {
        const Array arrays = resource->surface_get_arrays(surface);
        if (arrays.size() == Mesh::ARRAY_MAX && arrays[Mesh::ARRAY_BONES].get_type() == Variant::PACKED_INT32_ARRAY) {
            const PackedInt32Array bones = arrays[Mesh::ARRAY_BONES];
            if (!bones.is_empty()) return true;
        }
    }
    return false;
}

}

void GoreComponent::_bind_methods() {
#define BIND_GORE(type, name, ...) \
    ClassDB::bind_method(D_METHOD("set_" #name, "value"), &GoreComponent::set_##name); \
    ClassDB::bind_method(D_METHOD("get_" #name), &GoreComponent::get_##name); \
    ADD_PROPERTY(PropertyInfo(Variant::type, #name, __VA_ARGS__), "set_" #name, "get_" #name);

    ADD_GROUP("Blood Pools", "");
    BIND_GORE(BOOL, enable_blood_pool_decal, PROPERTY_HINT_NONE)
    BIND_GORE(FLOAT, blood_pool_scale, PROPERTY_HINT_RANGE, "0,5,0.01,or_greater")
    BIND_GORE(FLOAT, blood_decal_lifetime, PROPERTY_HINT_RANGE, "0,120,0.1,or_greater,suffix:s")
    BIND_GORE(INT, allowed_surface_types_for_blood_decals, PROPERTY_HINT_LAYERS_3D_PHYSICS)
    BIND_GORE(BOOL, override_blood_decal, PROPERTY_HINT_NONE)
    BIND_GORE(OBJECT, blood_decal, PROPERTY_HINT_RESOURCE_TYPE, "Material")
    BIND_GORE(BOOL, override_blood_decal_texture, PROPERTY_HINT_NONE)
    BIND_GORE(OBJECT, blood_decal_texture, PROPERTY_HINT_RESOURCE_TYPE, "Texture2D")
    BIND_GORE(BOOL, use_world_space_tiling, PROPERTY_HINT_NONE)
    BIND_GORE(FLOAT, blood_decal_tile_size, PROPERTY_HINT_RANGE, "0.001,20,0.01,or_greater,suffix:m")

    ADD_GROUP("Blood Particles", "");
    BIND_GORE(BOOL, enable_blood_particles, PROPERTY_HINT_NONE)
    BIND_GORE(FLOAT, blood_particle_scale, PROPERTY_HINT_RANGE, "0,5,0.01,or_greater")
    BIND_GORE(BOOL, override_blood_particles, PROPERTY_HINT_NONE)
    BIND_GORE(OBJECT, fx_blood_burst, PROPERTY_HINT_RESOURCE_TYPE, "PackedScene")

    ADD_GROUP("Blood Paint", "");
    BIND_GORE(BOOL, enable_blood_skin_painting, PROPERTY_HINT_NONE)
    BIND_GORE(FLOAT, blood_paint_radius, PROPERTY_HINT_RANGE, "0,5,0.01,or_greater,suffix:m")
    BIND_GORE(FLOAT, blood_paint_limb_radius, PROPERTY_HINT_RANGE, "0,5,0.01,or_greater,suffix:m")
    BIND_GORE(FLOAT, blood_paint_falloff, PROPERTY_HINT_RANGE, "0,1,0.01")
    BIND_GORE(INT, blood_vertex_channel, PROPERTY_HINT_ENUM, "Red,Green,Blue,Alpha")
    BIND_GORE(FLOAT, blood_animation_time, PROPERTY_HINT_RANGE, "0,10,0.01,or_greater,suffix:s")
    BIND_GORE(BOOL, auto_apply_blood_material, PROPERTY_HINT_NONE)

    // Compatibility fields are retained in scenes and scripts.
    BIND_GORE(FLOAT, blood_paint_scale, PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE)
    BIND_GORE(INT, blood_animation_primitive_index, PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE)
#undef BIND_GORE
    ClassDB::bind_method(D_METHOD("initialize_vertex_colors"), &GoreComponent::initialize_vertex_colors);
    ClassDB::bind_method(D_METHOD("apply_blood", "bone_name", "radius", "hardness"), &GoreComponent::apply_blood, DEFVAL(0.75), DEFVAL(0.2));
    ClassDB::bind_method(D_METHOD("apply_blood_to_mesh", "mesh", "bone_name", "radius", "hardness"), &GoreComponent::apply_blood_to_mesh, DEFVAL(0.75), DEFVAL(0.2));
    ClassDB::bind_method(D_METHOD("apply_blood_to_static_mesh", "mesh", "world_location", "radius", "hardness"), &GoreComponent::apply_blood_to_static_mesh, DEFVAL(0.75), DEFVAL(0.2));
    ClassDB::bind_method(D_METHOD("remove_blood_from_static_mesh", "mesh"), &GoreComponent::remove_blood_from_static_mesh);
    ClassDB::bind_method(D_METHOD("spawn_blood_decal", "location", "normal", "attachment", "splatter_direction"), &GoreComponent::spawn_blood_decal, DEFVAL(nullptr), DEFVAL(Vector3(0, 1, 0)));
    ClassDB::bind_method(D_METHOD("spawn_bool_decal", "location", "normal", "attachment", "splatter_direction"), &GoreComponent::spawn_bool_decal, DEFVAL(nullptr), DEFVAL(Vector3(0, 1, 0)));
    ClassDB::bind_method(D_METHOD("spawn_blood_particles", "location", "direction", "attach_to_scene"),
            &GoreComponent::spawn_blood_particles, DEFVAL(true));
    ClassDB::bind_method(D_METHOD("spawn_blood_fx", "location", "direction", "hit_bone"), &GoreComponent::spawn_blood_fx, DEFVAL(StringName()));
    ClassDB::bind_static_method("GoreComponent", D_METHOD("sphere_mask", "center", "location", "radius", "hardness"), &GoreComponent::sphere_mask);
    ClassDB::bind_method(D_METHOD("begin_blood_animation"), &GoreComponent::begin_blood_animation);
    ClassDB::bind_method(D_METHOD("get_blood_animation"), &GoreComponent::get_blood_animation);
    ClassDB::bind_method(D_METHOD("_on_limbs_reset"), &GoreComponent::on_limbs_reset);
    ADD_SIGNAL(MethodInfo("blood_fx_spawned", PropertyInfo(Variant::VECTOR3, "location")));
}

void GoreComponent::_validate_property(PropertyInfo &p_property) const {
    const String name = p_property.name;
    const bool custom_pool_material = override_blood_decal && blood_decal.is_valid();
    bool visible = true;

    if (name == "blood_decal") {
        visible = enable_blood_pool_decal && override_blood_decal;
    } else if (name == "override_blood_decal_texture") {
        visible = enable_blood_pool_decal && !custom_pool_material;
    } else if (name == "blood_decal_texture") {
        visible = enable_blood_pool_decal && !custom_pool_material && override_blood_decal_texture;
    } else if (name == "blood_decal_tile_size") {
        visible = enable_blood_pool_decal && !custom_pool_material && use_world_space_tiling;
    } else if (name == "blood_pool_scale" || name == "blood_decal_lifetime" ||
            name == "allowed_surface_types_for_blood_decals" || name == "override_blood_decal" ||
            name == "use_world_space_tiling") {
        visible = enable_blood_pool_decal;
    } else if (name == "fx_blood_burst") {
        visible = enable_blood_particles && override_blood_particles;
    } else if (name == "blood_particle_scale" || name == "override_blood_particles") {
        visible = enable_blood_particles;
    } else if (name == "blood_paint_radius" || name == "blood_paint_limb_radius" ||
            name == "blood_paint_falloff" || name == "blood_vertex_channel" ||
            name == "blood_animation_time" || name == "auto_apply_blood_material") {
        visible = enable_blood_skin_painting;
    }

    if (!visible) {
        p_property.usage &= ~PROPERTY_USAGE_EDITOR;
    }
}

void GoreComponent::_ready() {
    DismembermentComponent::_ready();
    if (!is_connected("limbs_reset", Callable(this, "_on_limbs_reset"))) connect("limbs_reset", Callable(this, "_on_limbs_reset"));
    if (!Engine::get_singleton()->is_editor_hint()) call_deferred("initialize_vertex_colors");
    set_process(true);
}

void GoreComponent::on_limbs_reset() {
    blood_animation = 0.0;
    blood_animating = false;
    initialized_vertex_colors = false;
    initialize_vertex_colors();
}

void GoreComponent::_process(double p_delta) {
    if (!blood_animating) return;
    blood_animation = std::clamp(blood_animation + p_delta / std::max(0.001, blood_animation_time), 0.0, 1.0);
    set_blood_animation(get_skeletal_mesh_component(), blood_animation);
    if (blood_animation >= 1.0) blood_animating = false;
}

double GoreComponent::sphere_mask(const Vector3 &p_center, const Vector3 &p_location, double p_radius, double p_hardness) {
    if (p_radius <= 0) return 0;
    return std::clamp((1.0 - p_center.distance_to(p_location) / p_radius) / std::max(0.00001, 1.0 - p_hardness), 0.0, 1.0);
}

void GoreComponent::install_blood_material(MeshInstance3D *p_mesh) {
    if (!p_mesh || !auto_apply_blood_material || p_mesh->get_mesh().is_null()) return;
    const uint64_t owner_id = uint64_t(p_mesh->get_instance_id());
    auto convert = [&](const Ref<Material> &source) -> Ref<Material> {
        Ref<ShaderMaterial> existing = source;
        if (existing.is_valid()) {
            // Core cloning also copies the global material override. Detach our
            // material per mesh before changing animation, so limb blood never
            // changes the source body's shader uniforms or another character.
            if (existing->has_meta("godot_dismemberment_material_owner") && uint64_t(int64_t(existing->get_meta("godot_dismemberment_material_owner"))) != owner_id) {
                Ref<ShaderMaterial> copy = existing->duplicate();
                copy->set_meta("godot_dismemberment_material_owner", int64_t(owner_id));
                return copy;
            }
            return existing; // Custom shaders remain the user's responsibility.
        }
        Ref<Shader> shader = ResourceLoader::get_singleton()->load("res://addons/godot-dismemberment/shaders/blood_skin.gdshader");
        if (shader.is_null()) return source;
        Ref<ShaderMaterial> material;
        material.instantiate();
        material->set_shader(shader);
        material->set_meta("godot_dismemberment_material_owner", int64_t(owner_id));
        Ref<BaseMaterial3D> base = source;
        if (base.is_valid()) {
            material->set_shader_parameter("base_color", base->get_albedo());
            material->set_shader_parameter("roughness", base->get_roughness());
            material->set_shader_parameter("metallic", base->get_metallic());
            material->set_shader_parameter("specular", base->get_specular());
            material->set_shader_parameter("normal_scale", base->get_normal_scale());
            material->set_shader_parameter("cull_mode", int(base->get_cull_mode()));
            material->set_shader_parameter("uv1_scale", base->get_uv1_scale());
            material->set_shader_parameter("uv1_offset", base->get_uv1_offset());
            material->set_shader_parameter("uv2_scale", base->get_uv2_scale());
            material->set_shader_parameter("uv2_offset", base->get_uv2_offset());
            material->set_shader_parameter("texture_repeat", base->get_flag(BaseMaterial3D::FLAG_USE_TEXTURE_REPEAT));
            material->set_shader_parameter("roughness_texture_channel", int(base->get_roughness_texture_channel()));
            material->set_shader_parameter("metallic_texture_channel", int(base->get_metallic_texture_channel()));
            material->set_shader_parameter("ao_texture_channel", int(base->get_ao_texture_channel()));
            material->set_shader_parameter("ao_light_affect", base->get_ao_light_affect());
            material->set_shader_parameter("enable_ao", base->get_feature(BaseMaterial3D::FEATURE_AMBIENT_OCCLUSION));
            material->set_shader_parameter("ao_on_uv2", base->get_flag(BaseMaterial3D::FLAG_AO_ON_UV2));
            material->set_shader_parameter("emission_on_uv2", base->get_flag(BaseMaterial3D::FLAG_EMISSION_ON_UV2));
            material->set_shader_parameter("emission_multiply", base->get_emission_operator() == BaseMaterial3D::EMISSION_OP_MULTIPLY);
            const bool emission_enabled = base->get_feature(BaseMaterial3D::FEATURE_EMISSION);
            material->set_shader_parameter("emission_color", emission_enabled ? base->get_emission() : Color(0, 0, 0));
            material->set_shader_parameter("emission_energy", emission_enabled ? base->get_emission_energy_multiplier() : 0.0);
            auto transfer_texture = [&](BaseMaterial3D::TextureParam slot, const StringName &parameter, const StringName &enabled, bool feature_enabled = true) {
                const Ref<Texture2D> texture = base->get_texture(slot);
                material->set_shader_parameter(enabled, texture.is_valid() && feature_enabled);
                if (texture.is_valid()) material->set_shader_parameter(parameter, texture);
            };
            transfer_texture(BaseMaterial3D::TEXTURE_ALBEDO, "base_texture", "use_base_texture");
            transfer_texture(BaseMaterial3D::TEXTURE_NORMAL, "normal_texture", "use_normal_texture", base->get_feature(BaseMaterial3D::FEATURE_NORMAL_MAPPING));
            transfer_texture(BaseMaterial3D::TEXTURE_ROUGHNESS, "roughness_texture", "use_roughness_texture");
            transfer_texture(BaseMaterial3D::TEXTURE_METALLIC, "metallic_texture", "use_metallic_texture");
            transfer_texture(BaseMaterial3D::TEXTURE_AMBIENT_OCCLUSION, "ao_texture", "use_ao_texture", base->get_feature(BaseMaterial3D::FEATURE_AMBIENT_OCCLUSION));
            transfer_texture(BaseMaterial3D::TEXTURE_ORM, "orm_texture", "use_orm_texture");
            transfer_texture(BaseMaterial3D::TEXTURE_EMISSION, "emission_texture", "use_emission_texture", emission_enabled);
            if (base->get_transparency() != BaseMaterial3D::TRANSPARENCY_DISABLED) {
                Ref<Shader> transparent_shader;
                transparent_shader.instantiate();
                String alpha_output = "ALPHA = base.a;\n";
                if (base->get_transparency() == BaseMaterial3D::TRANSPARENCY_ALPHA_SCISSOR) alpha_output += "ALPHA_SCISSOR_THRESHOLD = " + String::num(base->get_alpha_scissor_threshold()) + ";\n";
                if (base->get_transparency() == BaseMaterial3D::TRANSPARENCY_ALPHA_HASH) alpha_output += "ALPHA_HASH_SCALE = " + String::num(base->get_alpha_hash_scale()) + ";\n";
                String code = shader->get_code().replace("// TRANSPARENCY_OUTPUT:", alpha_output + "// TRANSPARENCY_OUTPUT:");
                if (base->get_transparency() == BaseMaterial3D::TRANSPARENCY_ALPHA_DEPTH_PRE_PASS) code = code.replace("render_mode cull_disabled;", "render_mode cull_disabled, depth_prepass_alpha;");
                transparent_shader->set_code(code);
                material->set_shader(transparent_shader);
            }
        }
        material->set_shader_parameter("blood_vertex_channel", std::clamp(blood_vertex_channel, 0, 3));
        material->set_shader_parameter("blood_animation", 0.0);
        if (ResourceLoader::get_singleton()->exists("res://addons/godot-dismemberment/textures/cloud_noise.png")) {
            Ref<Texture2D> noise = ResourceLoader::get_singleton()->load("res://addons/godot-dismemberment/textures/cloud_noise.png");
            material->set_shader_parameter("blood_noise", noise);
            material->set_shader_parameter("use_blood_noise", true);
        }
        return material;
    };
    // A global override takes precedence over every surface override. Convert
    // that slot itself rather than installing invisible per-surface materials.
    const Ref<Material> global_override = p_mesh->get_material_override();
    if (global_override.is_valid()) {
        p_mesh->set_material_override(convert(global_override));
        return;
    }
    for (int s = 0; s < p_mesh->get_mesh()->get_surface_count(); ++s) {
        p_mesh->set_surface_override_material(s, convert(p_mesh->get_active_material(s)));
    }
}

void GoreComponent::paint_mesh(MeshInstance3D *p_mesh, const Vector3 &p_center_local, double p_radius, double p_hardness, bool p_clear) {
    if (!p_mesh || p_mesh->get_mesh().is_null()) return;
    Ref<Mesh> source = p_mesh->get_mesh();
    PackedFloat32Array morph_values;
    morph_values.resize(p_mesh->get_blend_shape_count());
    for (int b = 0; b < morph_values.size(); ++b) morph_values.set(b, p_mesh->get_blend_shape_value(b));
    Ref<ArrayMesh> output;
    output.instantiate();
    Ref<ArrayMesh> source_array = source;
    if (source_array.is_valid()) {
        for (int b = 0; b < source_array->get_blend_shape_count(); ++b) output->add_blend_shape(source_array->get_blend_shape_name(b));
        output->set_blend_shape_mode(source_array->get_blend_shape_mode());
    }
    const int channel = std::clamp(blood_vertex_channel, 0, 3);
    for (int s = 0; s < source->get_surface_count(); ++s) {
        Array arrays = source->surface_get_arrays(s);
        if (arrays.size() != Mesh::ARRAY_MAX) continue;
        const PackedVector3Array vertices = arrays[Mesh::ARRAY_VERTEX];
        const int vertex_count = vertices.size();
        PackedColorArray colors = arrays[Mesh::ARRAY_COLOR];
        if (colors.size() != vertex_count) {
            colors.resize(vertex_count);
            Color initial_color(1, 1, 1, 1);
            initial_color[channel] = 0;
            colors.fill(initial_color);
        }
        if (vertex_count > 0) {
            const Vector3 *positions = vertices.ptr();
            Color *painted_colors = colors.ptrw();
            for (int v = 0; v < vertex_count; ++v) {
                Color &color = painted_colors[v];
                color[channel] = p_clear ? 0.0 : std::max(double(color[channel]), sphere_mask(p_center_local, positions[v], p_radius, p_hardness));
            }
        }
        arrays[Mesh::ARRAY_COLOR] = colors;
        Array shapes;
        Dictionary lods;
        uint64_t flags = 0;
        if (source_array.is_valid()) {
            shapes = source_array->surface_get_blend_shape_arrays(s);
            lods = MeshPartition::get_surface_lods(source_array, s);
            const uint64_t format = source_array->surface_get_format(s);
            flags = format & ((uint64_t(0xfff) << Mesh::ARRAY_FORMAT_CUSTOM_BASE) | Mesh::ARRAY_FLAG_USE_DYNAMIC_UPDATE | Mesh::ARRAY_FLAG_USE_8_BONE_WEIGHTS);
        }
        PackedInt32Array bones = arrays[Mesh::ARRAY_BONES];
        if (vertices.size() > 0 && bones.size() == vertices.size() * 8) flags |= Mesh::ARRAY_FLAG_USE_8_BONE_WEIGHTS;
        output->add_surface_from_arrays(source_array.is_valid() ? source_array->surface_get_primitive_type(s) : Mesh::PRIMITIVE_TRIANGLES, arrays, shapes, lods, BitField<Mesh::ArrayFormat>(flags));
        output->surface_set_material(output->get_surface_count() - 1, source->surface_get_material(s));
        if (source_array.is_valid()) output->surface_set_name(output->get_surface_count() - 1, source_array->surface_get_name(s));
    }
    p_mesh->set_mesh(output);
    for (int b = 0; b < morph_values.size() && b < p_mesh->get_blend_shape_count(); ++b) p_mesh->set_blend_shape_value(b, morph_values[b]);
    install_blood_material(p_mesh);
}

void GoreComponent::initialize_vertex_colors() {
    if (!initialize()) return;
    TypedArray<MeshInstance3D> meshes = get_all_meshes();
    for (int i = 0; i < meshes.size(); ++i) {
        MeshInstance3D *mesh = Object::cast_to<MeshInstance3D>(meshes[i]);
        paint_mesh(mesh, Vector3(), 1.0, 0.2, true);
        set_blood_animation(mesh, 0.0);
    }
    initialized_vertex_colors = true;
}

void GoreComponent::apply_blood(const StringName &p_bone, double p_radius, double p_hardness) {
    if (!initialize()) return;
    if (!initialized_vertex_colors) initialize_vertex_colors();
    TypedArray<MeshInstance3D> meshes = get_all_meshes();
    for (int i = 0; i < meshes.size(); ++i) {
        MeshInstance3D *mesh = Object::cast_to<MeshInstance3D>(meshes[i]);
        if (mesh && !mesh->is_in_group("Ignore Blood") && !mesh->is_in_group("ignore_blood")) apply_blood_to_mesh(mesh, p_bone, p_radius, p_hardness);
    }
}

void GoreComponent::apply_blood_to_mesh(MeshInstance3D *p_mesh, const StringName &p_bone, double p_radius, double p_hardness) {
    Skeleton3D *skeleton = get_skeleton();
    if (!p_mesh || !skeleton) return;
    int bone = skeleton->find_bone(p_bone);
    if (bone < 0) return;
    if (p_mesh->is_in_group("Ignore Blood") || p_mesh->is_in_group("ignore_blood")) return;
    const Vector3 center = reference_bone_in_mesh(p_mesh, skeleton, bone);
    paint_mesh(p_mesh, center, p_radius, p_hardness, false);
    if (p_mesh == get_skeletal_mesh_component()) begin_blood_animation();
    else set_blood_animation(p_mesh, 1.0);
}

void GoreComponent::apply_blood_to_static_mesh(MeshInstance3D *p_mesh, const Vector3 &p_world_location, double p_radius, double p_hardness) {
    if (!p_mesh || p_mesh->is_in_group("Ignore Blood") || p_mesh->is_in_group("ignore_blood")) return;
    paint_mesh(p_mesh, p_mesh->to_local(p_world_location), p_radius, p_hardness, false);
    set_blood_animation(p_mesh, 1.0);
}

void GoreComponent::remove_blood_from_static_mesh(MeshInstance3D *p_mesh) {
    paint_mesh(p_mesh, Vector3(), 1.0, 0.2, true);
}

void GoreComponent::set_blood_animation(MeshInstance3D *p_mesh, double p_value) {
    if (!p_mesh || p_mesh->get_mesh().is_null()) return;
    const uint64_t owner_id = uint64_t(p_mesh->get_instance_id());
    auto update_animation = [&](const Ref<Material> &active) -> Ref<ShaderMaterial> {
        Ref<ShaderMaterial> material = active;
        if (material.is_null()) return {};
        if (material->has_meta("godot_dismemberment_material_owner")) {
            if (uint64_t(int64_t(material->get_meta("godot_dismemberment_material_owner"))) == owner_id) {
                material->set_shader_parameter("blood_animation", p_value);
                return material;
            }
        } else {
            const Ref<Shader> shader = material->get_shader();
            if (shader.is_null()) return {};
            bool has_animation = false;
            const Array uniforms = shader->get_shader_uniform_list();
            for (int i = 0; i < uniforms.size(); ++i) {
                const Dictionary uniform = uniforms[i];
                const StringName name = uniform.get("name", StringName());
                if (name == StringName("blood_animation") && int(uniform.get("type", Variant::NIL)) == Variant::FLOAT) {
                    has_animation = true;
                    break;
                }
            }
            if (!has_animation) return {};
        }

        // Match EnGore's per-component primitive value even when the shader
        // resource is shared or automatic standard-material conversion is off.
        Ref<ShaderMaterial> local = material->duplicate();
        local->set_meta("godot_dismemberment_material_owner", int64_t(owner_id));
        local->set_shader_parameter("blood_animation", p_value);
        return local;
    };

    const Ref<Material> global_override = p_mesh->get_material_override();
    if (global_override.is_valid()) {
        const Ref<ShaderMaterial> material = update_animation(global_override);
        if (material.is_valid() && material.ptr() != global_override.ptr()) p_mesh->set_material_override(material);
    } else {
        for (int s = 0; s < p_mesh->get_mesh()->get_surface_count(); ++s) {
            const Ref<Material> active = p_mesh->get_active_material(s);
            const Ref<ShaderMaterial> material = update_animation(active);
            if (material.is_valid() && material.ptr() != active.ptr()) p_mesh->set_surface_override_material(s, material);
        }
    }
    p_mesh->set_meta("blood_animation", p_value);
}

void GoreComponent::begin_blood_animation() {
    if (blood_animation > 0.0) return;
    blood_animating = true;
}

void GoreComponent::pre_dismemberment(const StringName &p_bone, const Vector3 &p_impulse) {
    DismembermentComponent::pre_dismemberment(p_bone, p_impulse);
    Skeleton3D *skeleton = get_skeleton();
    if (!skeleton) return;
    int bone = skeleton->find_bone(p_bone);
    if (bone < 0) return;
    current_cut_world = skeleton->get_global_transform().xform(evaluated_bone_pose(skeleton, get_skeletal_mesh_component(), bone).origin);
    if (enable_blood_particles) spawn_blood_particles(current_cut_world, p_impulse);
    if (enable_blood_pool_decal) line_trace_for_blood_pool(current_cut_world, p_impulse.normalized());
    // Source EnGore paints after cloning, so the detached limb inherits only
    // earlier wounds, never the main body's larger radius for this cut.
    if (enable_blood_skin_painting && !initialized_vertex_colors) initialize_vertex_colors();
}

void GoreComponent::post_dismemberment(const StringName &p_bone, DismemberedLimb *p_limb) {
    if (enable_blood_skin_painting && p_limb) {
        const Vector3 cut_world = p_limb->get_bone_transform().origin;
        apply_blood(p_bone, blood_paint_radius, blood_paint_falloff);
        TypedArray<MeshInstance3D> meshes = p_limb->get_meshes();
        for (int i = 0; i < meshes.size(); ++i) {
            MeshInstance3D *mesh = Object::cast_to<MeshInstance3D>(meshes[i]);
            // Collapse/articulated meshes retain rest-space vertices and Skin.
            // Only CPU pose-baked geometry and static attachments use world hit.
            if (has_skin_weights(mesh)) apply_blood_to_mesh(mesh, p_bone, blood_paint_limb_radius, blood_paint_falloff);
            else apply_blood_to_static_mesh(mesh, cut_world, blood_paint_limb_radius, blood_paint_falloff);
        }
    }
    DismembermentComponent::post_dismemberment(p_bone, p_limb);
}

BloodPool *GoreComponent::spawn_blood_decal(const Vector3 &p_location, const Vector3 &p_normal, Node3D *p_attachment, const Vector3 &p_splatter_direction) {
    if (!is_inside_tree()) return nullptr;
    BloodPool *pool = memnew(BloodPool);
    pool->set_name("BloodPool");
    pool->set_start_delay(0.25);
    pool->set_max_lifetime(blood_decal_lifetime);
    pool->set_interp_time(0.3);
    const double elongation = use_world_space_tiling ? (2.0 - 1.5 * std::abs(p_splatter_direction.normalized().y)) : 0.5;
    pool->set_decal_size(Vector3(0.5 * blood_pool_scale, 0.12, elongation * blood_pool_scale));
    pool->set_use_world_space_tiling(use_world_space_tiling);
    pool->set_tile_size(blood_decal_tile_size);
    if (override_blood_decal) pool->set_decal_material(blood_decal);
    if (override_blood_decal_texture) pool->set_decal_texture(blood_decal_texture);
    Node *parent = p_attachment ? static_cast<Node *>(p_attachment) : get_tree()->get_current_scene();
    if (!parent) parent = get_parent();
    if (!parent) { memdelete(pool); return nullptr; }
    parent->add_child(pool);
    pool->set_global_position(p_location);
    pool->configure(p_normal, p_splatter_direction);
    return pool;
}

void GoreComponent::line_trace_for_blood_pool(const Vector3 &p_location, const Vector3 &p_direction) {
    if (!is_inside_tree() || get_world_3d().is_null()) return;
    Vector3 direction = p_direction;
    direction.y = -0.7;
    Ref<PhysicsRayQueryParameters3D> query = PhysicsRayQueryParameters3D::create(p_location, p_location + direction * 20.0, allowed_surface_types_for_blood_decals);
    Dictionary hit = get_world_3d()->get_direct_space_state()->intersect_ray(query);
    if (hit.is_empty()) return;
    Node3D *attachment = Object::cast_to<Node3D>(hit.get("collider", Variant()));
    spawn_blood_decal(hit["position"], hit["normal"], attachment, p_direction);
}

namespace {

struct BloodBurstEmitter {
    const char *name;
    const char *texture_path;
    int count;
    bool scale_count;
    Vector3 direction;
    float cone_half_angle;
    Vector2 speed_range;
    Vector2 lifetime_range;
    Vector2 minimum_size;
    Vector2 maximum_size;
    float angle_maximum;
    float damping;
    Vector3 size_curve;
    float size_curve_tangent;
    Vector2 erosion_range;
    bool erosion_from_lifetime;
    float thinness;
    float softness;
    float linear_red;
};

CPUParticles3D *make_blood_burst_emitter(const BloodBurstEmitter &settings, const Ref<Shader> &shader,
        real_t scale) {
    // Niagara converts the size-scaled count from float to int by truncation.
    // The Godot particle amount property supports at most 1,000,000 particles.
    const int count = settings.scale_count ?
            int(std::min(double(settings.count) * scale, 1000000.0)) : settings.count;
    if (count == 0) return nullptr;

    ResourceLoader *loader = ResourceLoader::get_singleton();
    Ref<Texture2D> texture;
    if (settings.texture_path) {
        if (!loader->exists(settings.texture_path)) return nullptr;
        texture = loader->load(settings.texture_path);
        if (texture.is_null()) return nullptr;
    }

    const bool velocity_aligned = settings.texture_path == nullptr;
    const real_t lifetime_scale = velocity_aligned ? 1.0 : scale;
    const real_t maximum_lifetime = settings.lifetime_range.y * lifetime_scale;
    CPUParticles3D *particles = memnew(CPUParticles3D);
    particles->set_name(settings.name);
    particles->set_amount(count);
    particles->set_lifetime(maximum_lifetime);
    particles->set_lifetime_randomness(1.0 - settings.lifetime_range.x / settings.lifetime_range.y);
    particles->set_one_shot(true);
    particles->set_explosiveness_ratio(1.0);
    particles->set_use_local_coordinates(false);
    particles->set_draw_order(CPUParticles3D::DRAW_ORDER_LIFETIME);
    particles->set_direction(settings.direction.normalized());
    particles->set_spread(settings.cone_half_angle);
    particles->set_gravity(Vector3(0, -9.8, 0));
    particles->set_param_min(CPUParticles3D::PARAM_INITIAL_LINEAR_VELOCITY, settings.speed_range.x);
    particles->set_param_max(CPUParticles3D::PARAM_INITIAL_LINEAR_VELOCITY, settings.speed_range.y);
    particles->set_param_max(CPUParticles3D::PARAM_ANGLE, settings.angle_maximum);
    // CPUParticles3D uses linear speed damping for Niagara's Drag module.
    particles->set_param_min(CPUParticles3D::PARAM_DAMPING, settings.damping);
    particles->set_param_max(CPUParticles3D::PARAM_DAMPING, settings.damping);
    particles->set_param_max(CPUParticles3D::PARAM_ANIM_OFFSET, 1.0);
    particles->set_particle_flag(CPUParticles3D::PARTICLE_FLAG_ALIGN_Y_TO_VELOCITY, velocity_aligned);

    Ref<QuadMesh> mesh;
    mesh.instantiate();
    mesh->set_size(settings.maximum_size * scale);
    Ref<ShaderMaterial> material;
    material.instantiate();
    material->set_shader(shader);
    if (texture.is_valid()) material->set_shader_parameter("splatter_mask", texture);
    material->set_shader_parameter("velocity_aligned", velocity_aligned);
    material->set_shader_parameter("minimum_size_ratio", settings.minimum_size / settings.maximum_size);
    material->set_shader_parameter("size_curve", settings.size_curve);
    material->set_shader_parameter("size_curve_tangent", settings.size_curve_tangent);
    material->set_shader_parameter("erosion_range", settings.erosion_range);
    material->set_shader_parameter("erosion_from_lifetime", settings.erosion_from_lifetime);
    material->set_shader_parameter("maximum_lifetime", maximum_lifetime);
    material->set_shader_parameter("thinness", settings.thinness);
    material->set_shader_parameter("softness", settings.softness);
    material->set_shader_parameter("linear_red", settings.linear_red);
    mesh->set_material(material);
    particles->set_mesh(mesh);
    return particles;
}

} // namespace

Node3D *GoreComponent::spawn_blood_particles(const Vector3 &p_location, const Vector3 &p_direction, bool p_attach_to_scene) {
    if (!is_inside_tree() || !p_location.is_finite() || !Math::is_finite(real_t(blood_particle_scale * 2.0))) {
        return nullptr;
    }
    Node *parent = get_tree()->get_current_scene();
    if (!parent) parent = get_parent();
    if (!parent) return nullptr;

    const real_t scale = std::max(0.001, blood_particle_scale);
    Node3D *effect = nullptr;
    double cleanup_delay = 2.5;
    if (override_blood_particles) {
        if (fx_blood_burst.is_null()) return nullptr;
        Node *node = fx_blood_burst->instantiate();
        effect = Object::cast_to<Node3D>(node);
        if (!effect) {
            if (node) memdelete(node);
            return nullptr;
        }
    } else {
        // NS_DIS_BloodBurst's embedded emitters, in system order. Sizes and
        // speeds convert from centimetres, axes from Unreal Z-up to Godot Y-up.
        // The exported graph's connected dynamic inputs determine the ranges.
        static const BloodBurstEmitter settings[] = {
            { "BloodBurst", "res://addons/godot-dismemberment/textures/blood_01.png", 10, false,
                Vector3(1, 0.4, 0), 5.0, Vector2(1.0, 5.0), Vector2(0.5, 1.0),
                Vector2(0.5, 0.5), Vector2(1.5, 1.5), 360.0, 0.0,
                Vector3(0.2, 0.45, 1.0), 1.0, Vector2(0.6, 0.78), false, 1.0, 0.01, 0.05 },
            { "BloodBurst001", "res://addons/godot-dismemberment/textures/blood_02.png", 10, true,
                Vector3(1, 0.4, 0), 5.0, Vector2(1.0, 5.0), Vector2(0.7, 2.0),
                Vector2(0.75, 0.5), Vector2(0.75, 0.5), 0.0, 0.0,
                Vector3(0.186157, 0.417612, 1.0), 1.0, Vector2(0.85, 0.85), false, 2.0, 0.01, 0.1 },
            { "BloodBurst002", "res://addons/godot-dismemberment/textures/blood_03.png", 7, false,
                Vector3(0, 1, 0), 27.5, Vector2(1.0, 4.5), Vector2(0.3, 1.0),
                Vector2(0.45, 0.45), Vector2(0.9, 0.9), 360.0, 1.0,
                Vector3(0.2, 1.0, 0.7), 0.7, Vector2(1.0, 1.0), true, 0.3, 0.0, 0.05 },
            { "BloodParticle", nullptr, 100, false,
                Vector3(1, 1, 0), 27.5, Vector2(1.0, 5.0), Vector2(0.3, 1.0),
                Vector2(0.005, 0.025), Vector2(0.01, 0.045), 0.0, 0.0,
                Vector3(), 0.0, Vector2(), false, 1.0, 0.0, 0.0625 },
        };

        Ref<Shader> shader = ResourceLoader::get_singleton()->load(
                "res://addons/godot-dismemberment/shaders/blood_burst.gdshader");
        if (shader.is_null()) return nullptr;
        effect = memnew(Node3D);
        double maximum_lifetime = 0.0;
        for (const BloodBurstEmitter &setting : settings) {
            CPUParticles3D *particles = make_blood_burst_emitter(setting, shader, scale);
            if (!particles) continue;
            effect->add_child(particles);
            maximum_lifetime = std::max(maximum_lifetime, particles->get_lifetime());
        }
        // Leave enough time for the longest particles to finish even at non-unit scale.
        cleanup_delay = maximum_lifetime + 0.1;
    }

    const Vector3 absolute_direction = p_direction.abs();
    const real_t largest_component = std::max({ absolute_direction.x, absolute_direction.y, absolute_direction.z });
    const Vector3 forward = !p_direction.is_finite() || largest_component == 0.0 ?
            Vector3(1, 0, 0) : (p_direction / largest_component).normalized();
    const real_t horizontal_component = std::max(Math::abs(forward.x), Math::abs(forward.z));
    const Vector3 right = horizontal_component == 0.0 ? Vector3(0, 0, 1) :
            (Vector3(-forward.z, 0, forward.x) / horizontal_component).normalized();
    const Basis orientation(forward, right.cross(forward), right);
    effect->set_name("BloodBurst");
    effect->set_as_top_level(true);
    effect->set_transform(Transform3D(orientation.scaled(Vector3(scale, scale, scale)), p_location));
    if (p_attach_to_scene) parent->add_child(effect);

    Timer *timer = memnew(Timer);
    timer->set_wait_time(cleanup_delay);
    timer->set_one_shot(true);
    timer->set_autostart(true);
    timer->connect("timeout", Callable(effect, "queue_free"));
    effect->add_child(timer);
    return effect;
}

void GoreComponent::spawn_blood_fx(const Vector3 &p_location, const Vector3 &p_direction, const StringName &p_hit_bone) {
    spawn_blood_particles(p_location, p_direction);
    line_trace_for_blood_pool(p_location, p_direction.normalized());
    if (!p_hit_bone.is_empty()) apply_blood(p_hit_bone);
    emit_signal("blood_fx_spawned", p_location);
}
}
