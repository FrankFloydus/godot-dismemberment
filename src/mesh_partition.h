#pragma once

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/material.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/skeleton3d.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>
#include <cstdint>
#include <vector>

namespace godot {

struct MeshPoseSurface {
    Array arrays;
    Ref<Material> material;
    String name;
    uint64_t format_flags = 0;
};

// Detached vertices are baked in the source MeshInstance3D local frame, not the
// severed bone frame. Place the detached instance at the source global transform.
// Both outputs own compact surface arrays; the input mesh is never modified.
class MeshPartition : public RefCounted {
    GDCLASS(MeshPartition, RefCounted)

protected:
    static void _bind_methods();

public:
    static Dictionary isolate_limb(MeshInstance3D *mesh, Skeleton3D *skeleton,
            const StringName &bone, double threshold = 0.5, bool bake_pose = true);
    // Bake the complete posed triangle mesh in MeshInstance3D local space.
    // The returned mesh has no Skin or blend shapes and uses the original instance transform.
    static Ref<ArrayMesh> snapshot_pose(MeshInstance3D *mesh, Skeleton3D *skeleton);
    // Main-thread capture of posed surface arrays without creating a render mesh.
    // Replaces the output only when every source surface has been captured.
    static bool snapshot_pose_surfaces(MeshInstance3D *mesh, Skeleton3D *skeleton, std::vector<MeshPoseSurface> &surfaces);
    // Safe LOD retrieval for the 4.3 baseline, whose public server dictionary
    // returns malformed LOD entries. Used when rebuilding painted ArrayMeshes.
    static Dictionary get_surface_lods(const Ref<ArrayMesh> &mesh, int surface);
};

}
