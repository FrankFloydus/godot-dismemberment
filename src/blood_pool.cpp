#include "blood_pool.h"

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/plane_mesh.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/shader.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <algorithm>
#include <cmath>

namespace godot {

void BloodPool::_bind_methods() {
#define BIND_POOL(type, name) \
    ClassDB::bind_method(D_METHOD("set_" #name, "value"), &BloodPool::set_##name); \
    ClassDB::bind_method(D_METHOD("get_" #name), &BloodPool::get_##name); \
    ADD_PROPERTY(PropertyInfo(Variant::type, #name), "set_" #name, "get_" #name);
    BIND_POOL(FLOAT, start_delay)
    BIND_POOL(FLOAT, max_lifetime)
    BIND_POOL(FLOAT, interp_time)
    BIND_POOL(VECTOR3, decal_size)
    BIND_POOL(VECTOR3, decal_rotation)
    ClassDB::bind_method(D_METHOD("set_decal_material", "value"), &BloodPool::set_decal_material);
    ClassDB::bind_method(D_METHOD("get_decal_material"), &BloodPool::get_decal_material);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "decal_material", PROPERTY_HINT_RESOURCE_TYPE, "Material"), "set_decal_material", "get_decal_material");
    ClassDB::bind_method(D_METHOD("set_decal_texture", "value"), &BloodPool::set_decal_texture);
    ClassDB::bind_method(D_METHOD("get_decal_texture"), &BloodPool::get_decal_texture);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "decal_texture", PROPERTY_HINT_RESOURCE_TYPE, "Texture2D"), "set_decal_texture", "get_decal_texture");
    BIND_POOL(BOOL, use_world_space_tiling)
    BIND_POOL(FLOAT, tile_size)
#undef BIND_POOL
    ClassDB::bind_method(D_METHOD("configure", "normal", "direction"), &BloodPool::configure);
    ClassDB::bind_method(D_METHOD("get_age"), &BloodPool::get_age);
}

void BloodPool::configure(const Vector3 &p_normal, const Vector3 &p_direction) {
    Vector3 up = p_normal.normalized();
    if (up.is_zero_approx()) up = Vector3(0, 1, 0);
    Vector3 along = p_direction - up * p_direction.dot(up);
    if (along.length_squared() < 0.0001) along = up.cross(Vector3(1, 0, 0));
    if (along.length_squared() < 0.0001) along = up.cross(Vector3(0, 0, 1));
    along.normalize();
    Vector3 right = up.cross(along).normalized();
    const Basis surface_basis(right, up, along);
    if (is_inside_tree()) {
        set_global_basis(surface_basis);
    } else {
        set_basis(surface_basis);
    }
}

void BloodPool::_ready() {
    // Decal has no support in Compatibility. The fallback uses exactly the same
    // procedurally generated texture, so every renderer retains visible pools.
    Ref<Image> image = Image::create_empty(96, 96, false, Image::FORMAT_RGBA8);
    for (int y = 0; y < 96; ++y) {
        for (int x = 0; x < 96; ++x) {
            const double px = (double(x) + 0.5) / 48.0 - 1.0;
            const double py = (double(y) + 0.5) / 48.0 - 1.0;
            const double angle = std::atan2(py, px);
            const double edge = 0.77 + 0.10 * std::sin(angle * 7.0) + 0.05 * std::sin(angle * 13.0 + 1.7);
            const double radius = std::sqrt(px * px + py * py);
            const double alpha = std::clamp((edge - radius) * 22.0, 0.0, 1.0);
            image->set_pixel(x, y, Color(0.22, 0.002, 0.008, alpha));
        }
    }
    Ref<Texture2D> texture = decal_texture;
    if (texture.is_null()) texture = ImageTexture::create_from_image(image);
    String rendering_method;
    RenderingServer *server = RenderingServer::get_singleton();
    if (server && server->has_method("get_current_rendering_method")) rendering_method = server->call("get_current_rendering_method");
    if (rendering_method.is_empty() && server) {
        String api = server->get_video_adapter_api_version();
        if (api.contains("Vulkan") || api.contains("Direct3D") || api.contains("Metal")) rendering_method = "forward_plus";
        else if (api.contains("OpenGL")) rendering_method = "gl_compatibility";
    }
    const bool can_project = rendering_method != "gl_compatibility" && rendering_method != "" && decal_material.is_null();
    const double yaw = Math::deg_to_rad(UtilityFunctions::randf_range(-10.0, 10.0));
    const Basis visual_rotation = Basis(Vector3(0, 1, 0), yaw) * Basis::from_euler(decal_rotation);
    if (can_project) {
        projected_decal = memnew(Decal);
        projected_decal->set_name("BloodDecal");
        projected_decal->set_texture(Decal::TEXTURE_ALBEDO, texture);
        projected_decal->set_size(Vector3(std::max(0.01f, decal_size.x * 2), std::max(0.08f, decal_size.y), std::max(0.01f, decal_size.z * 2)));
        projected_decal->set_basis(visual_rotation);
        add_child(projected_decal);
    } else {
        puddle = memnew(MeshInstance3D);
        puddle->set_name("BloodPoolCompatibility");
        Ref<PlaneMesh> mesh;
        mesh.instantiate();
        mesh->set_size(Vector2(std::max(0.01f, decal_size.x * 2), std::max(0.01f, decal_size.z * 2)));
        puddle->set_mesh(mesh);
        puddle->set_position(Vector3(0, 0.003, 0));
        puddle->set_basis(visual_rotation);
        puddle->set_cast_shadows_setting(GeometryInstance3D::SHADOW_CASTING_SETTING_OFF);
        puddle_shader.instantiate();
        Ref<Shader> shader = ResourceLoader::get_singleton()->load("res://addons/godot-dismemberment/shaders/blood_pool.gdshader");
        if (shader.is_null()) {
            shader.instantiate();
            shader->set_code("shader_type spatial; render_mode unshaded,cull_disabled,depth_draw_never; uniform sampler2D blood_texture:source_color; uniform float opacity=1.0; void fragment(){vec4 c=texture(blood_texture,UV);ALBEDO=c.rgb;ALPHA=c.a*opacity;}");
        }
        puddle_shader->set_shader(shader);
        puddle_shader->set_shader_parameter("blood_texture", texture);
        puddle_shader->set_shader_parameter("world_space_tiling", use_world_space_tiling);
        puddle_shader->set_shader_parameter("tile_size", tile_size);
        if (ResourceLoader::get_singleton()->exists("res://addons/godot-dismemberment/textures/cloud_noise.png")) {
            Ref<Texture2D> noise = ResourceLoader::get_singleton()->load("res://addons/godot-dismemberment/textures/cloud_noise.png");
            puddle_shader->set_shader_parameter("noise_texture", noise);
            puddle_shader->set_shader_parameter("use_noise_texture", true);
        }
        puddle->set_material_override(decal_material.is_valid() ? decal_material : Ref<Material>(puddle_shader));
        add_child(puddle);
    }
    _process(0.0);
    set_process(true);
}

void BloodPool::_process(double p_delta) {
    elapsed += p_delta;
    // Both decal fades use time since spawn. EnGore leaves the projection size fixed.
    constexpr double fade_in_duration = 0.3;
    const double fade_in = (elapsed - start_delay) / fade_in_duration;
    const bool persistent = max_lifetime <= 0.0;
    const double fade_out_start = max_lifetime / 5.0;
    const double fade_out = persistent ? 1.0 : 1.0 - (elapsed - fade_out_start) / max_lifetime;
    const double opacity = std::clamp(std::min(fade_in, fade_out), 0.0, 1.0);
    if (projected_decal) {
        projected_decal->set_modulate(Color(1, 1, 1, opacity));
    }
    if (puddle) {
        puddle->set_visible(opacity > 0.0);
        puddle_shader->set_shader_parameter("opacity", opacity);
        puddle_shader->set_shader_parameter("dryness", std::clamp((1.0 - opacity) * 3.0, 0.0, 1.0));
    }
    if (!persistent && elapsed >= fade_out_start + max_lifetime) queue_free();
}
}
