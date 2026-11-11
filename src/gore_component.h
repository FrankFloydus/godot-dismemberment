#pragma once

#include "dismemberment_component.h"
#include "blood_pool.h"
#include <godot_cpp/classes/material.hpp>
#include <godot_cpp/classes/packed_scene.hpp>
#include <godot_cpp/classes/texture2d.hpp>
#include <godot_cpp/variant/typed_array.hpp>

namespace godot {

class GoreComponent : public DismembermentComponent {
    GDCLASS(GoreComponent, DismembermentComponent)
    bool enable_blood_pool_decal = true;
    bool enable_blood_particles = true;
    bool enable_blood_skin_painting = true;
    double blood_pool_scale = 1.0;
    double blood_decal_lifetime = 60.0;
    bool override_blood_decal = false;
    Ref<Material> blood_decal;
    bool override_blood_decal_texture = false;
    Ref<Texture2D> blood_decal_texture;
    double blood_decal_tile_size = 7.5;
    bool use_world_space_tiling = true;
    uint32_t allowed_surface_types_for_blood_decals = 1;
    bool override_blood_particles = false;
    Ref<PackedScene> fx_blood_burst;
    double blood_particle_scale = 1.0;
    double blood_paint_scale = 1.0;
    double blood_paint_radius = 1.2;
    double blood_paint_limb_radius = 0.75;
    double blood_paint_falloff = 0.2;
    int blood_vertex_channel = 2;
    int blood_animation_primitive_index = 0;
    double blood_animation_time = 1.0;
    double blood_animation = 0.0;
    bool blood_animating = false;
    bool auto_apply_blood_material = true;
    bool initialized_vertex_colors = false;
    Vector3 current_cut_world;

    void line_trace_for_blood_pool(const Vector3 &p_location, const Vector3 &p_direction);
    void paint_mesh(MeshInstance3D *p_mesh, const Vector3 &p_center_local, double p_radius, double p_hardness, bool p_clear);
    void install_blood_material(MeshInstance3D *p_mesh);
    void set_blood_animation(MeshInstance3D *p_mesh, double p_value);
    void on_limbs_reset();

protected:
    static void _bind_methods();
    void _validate_property(PropertyInfo &p_property) const;
    void pre_dismemberment(const StringName &p_bone, const Vector3 &p_impulse) override;
    void post_dismemberment(const StringName &p_bone, DismemberedLimb *p_limb) override;

public:
    void _ready() override;
    void _process(double p_delta) override;
    void initialize_vertex_colors();
    void apply_blood(const StringName &p_bone, double p_radius = 0.75, double p_hardness = 0.2);
    void apply_blood_to_mesh(MeshInstance3D *p_mesh, const StringName &p_bone, double p_radius = 0.75, double p_hardness = 0.2);
    void apply_blood_to_static_mesh(MeshInstance3D *p_mesh, const Vector3 &p_world_location, double p_radius = 0.75, double p_hardness = 0.2);
    void remove_blood_from_static_mesh(MeshInstance3D *p_mesh);
    BloodPool *spawn_blood_decal(const Vector3 &p_location, const Vector3 &p_normal, Node3D *p_attachment = nullptr, const Vector3 &p_splatter_direction = Vector3(0, 1, 0));
    BloodPool *spawn_bool_decal(const Vector3 &p_location, const Vector3 &p_normal, Node3D *p_attachment = nullptr, const Vector3 &p_splatter_direction = Vector3(0, 1, 0)) { return spawn_blood_decal(p_location, p_normal, p_attachment, p_splatter_direction); }
    Node3D *spawn_blood_particles(const Vector3 &p_location, const Vector3 &p_direction);
    void spawn_blood_fx(const Vector3 &p_location, const Vector3 &p_direction, const StringName &p_hit_bone = StringName());
    static double sphere_mask(const Vector3 &p_center, const Vector3 &p_location, double p_radius, double p_hardness);
    void begin_blood_animation();
    double get_blood_animation() const { return blood_animation; }

#define GORE_PROPERTY(type, name) \
    void set_##name(type p_value) { name = p_value; } \
    type get_##name() const { return name; }
#define GORE_INSPECTOR_PROPERTY(type, name) \
    void set_##name(type p_value) { \
        if (name == p_value) return; \
        name = p_value; \
        notify_property_list_changed(); \
    } \
    type get_##name() const { return name; }

    GORE_INSPECTOR_PROPERTY(bool, enable_blood_pool_decal)
    GORE_PROPERTY(double, blood_pool_scale)
    GORE_PROPERTY(double, blood_decal_lifetime)
    GORE_PROPERTY(uint32_t, allowed_surface_types_for_blood_decals)
    GORE_INSPECTOR_PROPERTY(bool, override_blood_decal)
    GORE_INSPECTOR_PROPERTY(Ref<Material>, blood_decal)
    GORE_INSPECTOR_PROPERTY(bool, override_blood_decal_texture)
    GORE_PROPERTY(Ref<Texture2D>, blood_decal_texture)
    GORE_INSPECTOR_PROPERTY(bool, use_world_space_tiling)
    GORE_PROPERTY(double, blood_decal_tile_size)

    GORE_INSPECTOR_PROPERTY(bool, enable_blood_particles)
    GORE_PROPERTY(double, blood_particle_scale)
    GORE_INSPECTOR_PROPERTY(bool, override_blood_particles)
    GORE_PROPERTY(Ref<PackedScene>, fx_blood_burst)

    GORE_INSPECTOR_PROPERTY(bool, enable_blood_skin_painting)
    GORE_PROPERTY(double, blood_paint_radius)
    GORE_PROPERTY(double, blood_paint_limb_radius)
    GORE_PROPERTY(double, blood_paint_falloff)
    GORE_PROPERTY(int, blood_vertex_channel)
    GORE_PROPERTY(double, blood_animation_time)
    GORE_PROPERTY(bool, auto_apply_blood_material)
    GORE_PROPERTY(double, blood_paint_scale)
    GORE_PROPERTY(int, blood_animation_primitive_index)

#undef GORE_INSPECTOR_PROPERTY
#undef GORE_PROPERTY
};
}
