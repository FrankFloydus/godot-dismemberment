#pragma once

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/material.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
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
    static Dictionary slice_pose(MeshInstance3D *mesh, Skeleton3D *skeleton, const Plane &plane,
            const Ref<Material> &cap_material = Ref<Material>(), double epsilon = 0.000001);
};

}
