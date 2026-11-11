#pragma once

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/material.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/plane.hpp>

#include <atomic>
#include <memory>

namespace godot {

class MeshInstance3D;
class Skeleton3D;

class MeshPlaneSliceJob : public RefCounted {
    GDCLASS(MeshPlaneSliceJob, RefCounted)

    friend class MeshPlaneSlice;
    enum class Phase { EMPTY, READY, RUNNING, COMPLETE, FINISHED };
    struct State;
    std::unique_ptr<State> state;
    Plane requested_plane;
    Plane cut_plane;
    std::atomic<Phase> phase{ Phase::EMPTY };

protected:
    static void _bind_methods();

public:
    MeshPlaneSliceJob();
    ~MeshPlaneSliceJob() override;
    // Only compute() runs on a worker. Capture and finish use scene resources.
    bool compute();
    Plane get_cut_plane() const;
    Dictionary finish(const Ref<Material> &cap_material = Ref<Material>());
};

class MeshPlaneSlice : public RefCounted {
    GDCLASS(MeshPlaneSlice, RefCounted)

protected:
    static void _bind_methods();

public:
    static Dictionary slice_mesh(const Ref<ArrayMesh> &mesh, const Plane &plane,
            const Ref<Material> &cap_material = Ref<Material>(), double epsilon = 0.000001,
            bool include_surface_arrays = false, const Array &source_surfaces = Array());
    static Dictionary slice_mesh_pieces(const Ref<ArrayMesh> &mesh, const Plane &plane,
            const Ref<Material> &cap_material = Ref<Material>(), double epsilon = 0.000001);
    // Detach the capped positive component reached by a nearby mesh-local seed.
    static Dictionary sever_connected_piece(const Ref<ArrayMesh> &mesh, const Plane &plane, const Vector3 &limb_seed,
            const Ref<Material> &cap_material = Ref<Material>(), double epsilon = 0.000001, double max_seed_distance = 0.15);
    static Dictionary slice_pose(MeshInstance3D *mesh, Skeleton3D *skeleton, const Plane &plane,
            const Ref<Material> &cap_material = Ref<Material>(), double epsilon = 0.000001);
    static Ref<MeshPlaneSliceJob> capture_pose_job(MeshInstance3D *mesh, Skeleton3D *skeleton, const Plane &plane,
            double epsilon = 0.000001, bool prepare_hulls = false,
            const PackedStringArray &collapsed_roots = PackedStringArray(), bool fit_to_pose = false);
    static PackedVector3Array reduce_collision_hull(const PackedVector3Array &points);
};

}
