#pragma once

#include <godot_cpp/classes/rigid_body3d.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/classes/skeleton3d.hpp>
#include <godot_cpp/classes/physical_bone3d.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <vector>

namespace godot {

Transform3D evaluated_bone_pose(Skeleton3D *skeleton, MeshInstance3D *mesh, int bone);

// Pose information stays independent of engine-specific animation graph assets.
class DismemberedAnimInstance : public Resource {
    GDCLASS(DismemberedAnimInstance, Resource)
    StringName limb;
    StringName pelvis_bone_name = "pelvis";
    Array bone_poses;
protected:
    static void _bind_methods();
public:
    void set_limb(const StringName &value) { limb = value; }
    StringName get_limb() const { return limb; }
    void set_pelvis_bone_name(const StringName &value) { pelvis_bone_name = value; }
    StringName get_pelvis_bone_name() const { return pelvis_bone_name; }
    void capture_pose(Skeleton3D *skeleton);
    Array get_bone_poses() const { return bone_poses; }
    void apply_pose(Skeleton3D *skeleton) const;
};

class DismemberedLimb : public RigidBody3D {
    GDCLASS(DismemberedLimb, RigidBody3D)
    friend class DismembermentComponent;

    bool waiting_for_launch = false;
    StringName bone_name;
    Transform3D bone_transform;
    Ref<DismemberedAnimInstance> anim_instance;
    double lifetime = 0.0;
    double age = 0.0;
    uint64_t ragdoll_skeleton_id = 0;
    TypedArray<PhysicalBone3D> physical_bones;
    struct InheritedMotion { uint64_t body_id; Vector3 linear; Vector3 angular; };
    std::vector<InheritedMotion> inherited_motion;
    bool rigid_fallback_enabled = false;
    struct CollisionMesh { Ref<Mesh> mesh; Transform3D transform; };
    std::vector<CollisionMesh> collision_meshes;
    PackedStringArray hidden_bone_roots;
    std::vector<Transform3D> captured_global_poses;
    StringName collapse_root_bone;
    double complement_scale = 0.01;
    bool collapse_enabled = false;
protected:
    static void _bind_methods();
public:
    DismemberedLimb();
    void _ready() override;
    void _physics_process(double delta) override;
    void set_bone_name(const StringName &value) { bone_name = value; }
    StringName get_bone_name() const { return bone_name; }
    void set_bone_transform(const Transform3D &value) { bone_transform = value; }
    Transform3D get_bone_transform() const { return bone_transform; }
    void set_anim_instance(const Ref<DismemberedAnimInstance> &value) { anim_instance = value; }
    Ref<DismemberedAnimInstance> get_anim_instance() const { return anim_instance; }
    TypedArray<MeshInstance3D> get_meshes() const;
    void build_collision();
    bool prepare_articulated_physics(Skeleton3D *source, const StringName &root_bone, const PackedStringArray &missing_bones, uint32_t layer, uint32_t mask);
    Skeleton3D *get_ragdoll_skeleton() const;
    void begin_simulation(const Vector3 &impulse);
    void set_rigid_fallback_enabled(bool enabled) { rigid_fallback_enabled = enabled; }
    bool get_rigid_fallback_enabled() const { return rigid_fallback_enabled; }
    bool is_articulated() const { return !physical_bones.is_empty(); }
    Skeleton3D *prepare_pose_skeleton(Skeleton3D *source, MeshInstance3D *source_mesh = nullptr);
    void collapse_complement(const StringName &limb_root, double scale);
    void add_collision_mesh(const Ref<Mesh> &mesh, const Transform3D &transform);
    void set_hidden_bone_roots(const PackedStringArray &roots) { hidden_bone_roots = roots; }
    void apply_hidden_skin();
    void set_lifetime(double value) { lifetime = MAX(0.0, value); }
    double get_lifetime() const { return lifetime; }
};

}
