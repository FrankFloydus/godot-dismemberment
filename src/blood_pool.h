#pragma once

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/decal.hpp>
#include <godot_cpp/classes/material.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/shader_material.hpp>
#include <godot_cpp/classes/texture2d.hpp>

namespace godot {

// Native, renderer-independent blood pool. Godot uses metres and Y-up.
class BloodPool : public Node3D {
    GDCLASS(BloodPool, Node3D)
    double start_delay = 0.0;
    double max_lifetime = 60.0;
    double interp_time = 0.3; // Exposed in EnGore, but its decal keeps a fixed size.
    Vector3 decal_size = Vector3(0.5, 0.015, 0.5);
    Vector3 decal_rotation;
    Ref<Material> decal_material;
    Ref<Texture2D> decal_texture;
    bool use_world_space_tiling = true;
    double tile_size = 7.5;
    double elapsed = 0.0;
    MeshInstance3D *puddle = nullptr;
    Decal *projected_decal = nullptr;
    Ref<ShaderMaterial> puddle_shader;

protected:
    static void _bind_methods();

public:
    void _ready() override;
    void _process(double p_delta) override;
    void configure(const Vector3 &p_normal, const Vector3 &p_direction);

#define POOL_PROPERTY(type, name) \
    void set_##name(type p_value) { name = p_value; } \
    type get_##name() const { return name; }
    POOL_PROPERTY(double, start_delay)
    POOL_PROPERTY(double, max_lifetime)
    POOL_PROPERTY(double, interp_time)
    POOL_PROPERTY(Vector3, decal_size)
    POOL_PROPERTY(Vector3, decal_rotation)
    POOL_PROPERTY(Ref<Material>, decal_material)
    POOL_PROPERTY(Ref<Texture2D>, decal_texture)
    POOL_PROPERTY(bool, use_world_space_tiling)
    POOL_PROPERTY(double, tile_size)
#undef POOL_PROPERTY
    double get_age() const { return elapsed; }
};
}
