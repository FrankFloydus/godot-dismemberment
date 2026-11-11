#pragma once

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/material.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/plane.hpp>

namespace godot {

class MeshInstance3D;
class Skeleton3D;

class MeshPlaneSlice : public RefCounted {
    GDCLASS(MeshPlaneSlice, RefCounted)

protected:
    static void _bind_methods();

public:
    static Dictionary slice_mesh(const Ref<ArrayMesh> &mesh, const Plane &plane,
            const Ref<Material> &cap_material = Ref<Material>(), double epsilon = 0.000001);
    static Dictionary slice_mesh_pieces(const Ref<ArrayMesh> &mesh, const Plane &plane,
            const Ref<Material> &cap_material = Ref<Material>(), double epsilon = 0.000001);
    // Detach the capped positive component reached by a nearby mesh-local seed.
    static Dictionary sever_connected_piece(const Ref<ArrayMesh> &mesh, const Plane &plane, const Vector3 &limb_seed,
            const Ref<Material> &cap_material = Ref<Material>(), double epsilon = 0.000001, double max_seed_distance = 0.15);
    static Dictionary slice_pose(MeshInstance3D *mesh, Skeleton3D *skeleton, const Plane &plane,
            const Ref<Material> &cap_material = Ref<Material>(), double epsilon = 0.000001);
    static PackedVector3Array reduce_collision_hull(const PackedVector3Array &points);
};

}
