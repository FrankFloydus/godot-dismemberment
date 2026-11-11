#pragma once

#include "dismembered_limb.h"
#include "limb_map.h"
#include <godot_cpp/classes/material.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/skeleton3d.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/node_path.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <vector>

namespace godot {

class LimbMap;

class DismembermentComponent : public Node3D {
    GDCLASS(DismembermentComponent, Node3D)
    struct MeshState {
        uint64_t id = 0;
        Ref<Mesh> original;
        AABB original_custom_aabb;
        std::vector<Ref<Material>> original_surface_overrides;
    };
    struct TransferState {
        uint64_t id = 0;
        uint64_t parent_id = 0;
        Transform3D transform;
    };
    struct AttachmentVisibilityState {
        uint64_t id = 0;
        bool visible = true;
    };
    struct SourcePhysicsState {
        uint64_t id = 0;
        uint64_t parent_id = 0;
        int child_index = 0;
        Transform3D local_transform;
    };
    struct SourceSimulatorState {
        uint64_t id = 0;
        TypedArray<StringName> simulated_bones;
    };
    NodePath skeleton_path;
    NodePath mesh_path;
    uint64_t skeleton_id = 0;
    uint64_t mesh_id = 0;
    bool initialized = false;
    bool disable_dismemberment = false;
    bool support_attached_child_meshes = false;
    bool override_source_mesh = false;
    String source_mesh_component = "Mesh";
    StringName pelvis_bone_name = "pelvis";
    PackedStringArray excluded_bones;
    PackedStringArray whitelist_bones;
    Dictionary remapped_bones;
    PackedStringArray morph_targets_to_copy;
    bool update_mesh_bounds = false;
    int geometry_mode = 0;
    double collapse_scale = 0.01;
    Dictionary hidden_bone_scales;
    Dictionary hidden_bone_local_poses;
    double weight_threshold = 0.5;
    double limb_mass = 1.0;
    double limb_lifetime = 0.0;
    bool limb_rigid_fallback_enabled = false;
    uint32_t limb_collision_layer = 1;
    uint32_t limb_collision_mask = 1;
    bool network_enabled = false;
    int64_t owning_peer_id = 1;
    int replication_revision = 0;
    int remote_revision = -1;
    PackedStringArray dismembered_bones;
    PackedStringArray destroyed_bones;
    Array dismemberment_events;
    std::vector<SourcePhysicsState> source_physics_states;
    std::vector<SourceSimulatorState> source_simulator_states;
    uint64_t physics_quarantine_id = 0;
    Dictionary missing_limbs;
    std::vector<MeshState> source_states;
    std::vector<TransferState> transferred_nodes;
    std::vector<AttachmentVisibilityState> attachment_visibility;
    Ref<LimbMap> limb_map;
    String last_error;

    void configure_rpc();
    void dismember_internal(const StringName &bone_name, const Vector3 &impulse, bool canonical = false);
    void hide_internal(const StringName &bone_name);
    void transfer_attachments(const StringName &bone_name, DismemberedLimb *limb);
    void disable_missing_physics(const StringName &bone_name);
    void restore_attachments();
    void finish_dismemberment(uint64_t limb_id, const StringName &bone_name, const Vector3 &impulse);
    void request_dismemberment(const StringName &bone_name, const Vector3 &impulse);
    void receive_dismemberment(const StringName &bone_name, const Vector3 &impulse, int revision);
    void receive_state(const Dictionary &state);
    void on_peer_connected(int64_t peer_id);
    void enforce_hidden_bones();
    void hide_source_attachments();
    bool validate_bone(const StringName &bone_name) const;

protected:
    static void _bind_methods();
    void _validate_property(PropertyInfo &p_property) const;
    virtual void pre_dismemberment(const StringName &bone_name, const Vector3 &impulse);
    virtual void post_dismemberment(const StringName &bone_name, DismemberedLimb *limb);

public:
    enum GeometryMode { BONE_COLLAPSE = 0, TRIANGLE_PARTITION = 1 };
    DismembermentComponent();
    void _ready() override;
    void _exit_tree() override;
    void _process(double delta) override;
    void _physics_process(double delta) override;
    bool initialize();
    bool is_system_verified() const { return initialized; }
    String get_last_error() const { return last_error; }
    void set_skeletal_mesh_component_to_dismember(MeshInstance3D *mesh);
    MeshInstance3D *get_skeletal_mesh_component() const;
    Skeleton3D *get_skeleton() const;
    TypedArray<MeshInstance3D> get_all_meshes() const;
    TypedArray<MeshInstance3D> get_all_attached_meshes() const;
    PackedStringArray get_bone_name_options() const;
    Ref<LimbMap> get_limb_map() const;
    bool check_bone_filter(const StringName &bone_name) const;
    void dismember_limb(const StringName &bone_name, const Vector3 &impulse = Vector3());
    void destroy_limb(const StringName &bone_name);
    void reset_all_limbs();
    void clean_up_all_referenced_limbs();
    void clean_up_referenced_limb(const StringName &bone_name);
    DismemberedLimb *get_dismembered_limb_by_name(const StringName &bone_name) const;
    TypedArray<DismemberedLimb> get_all_dismembered_limbs() const;
    PackedStringArray get_dismembered_bones() const { return dismembered_bones; }
    Dictionary get_replication_state() const;
    bool apply_replication_state(const Dictionary &state);
    void synchronize_peer(int64_t peer_id);

    void set_skeleton_path(const NodePath &value) { skeleton_path = value; initialized = false; }
    NodePath get_skeleton_path() const { return skeleton_path; }
    void set_mesh_path(const NodePath &value);
    NodePath get_mesh_path() const { return mesh_path; }
    void set_disable_dismemberment(bool value) { disable_dismemberment = value; }
    bool get_disable_dismemberment() const { return disable_dismemberment; }
    void set_support_attached_child_meshes(bool value) { support_attached_child_meshes = value; initialized = false; }
    bool get_support_attached_child_meshes() const { return support_attached_child_meshes; }
    void set_override_source_mesh(bool value);
    bool get_override_source_mesh() const { return override_source_mesh; }
    void set_source_mesh_component(const String &value) { source_mesh_component = value; initialized = false; }
    String get_source_mesh_component() const { return source_mesh_component; }
    void set_pelvis_bone_name(const StringName &value) { pelvis_bone_name = value; }
    StringName get_pelvis_bone_name() const { return pelvis_bone_name; }
    void set_excluded_bones(const PackedStringArray &value) { excluded_bones = value; }
    PackedStringArray get_excluded_bones() const { return excluded_bones; }
    void set_whitelist_bones(const PackedStringArray &value) { whitelist_bones = value; }
    PackedStringArray get_whitelist_bones() const { return whitelist_bones; }
    void set_remapped_bones(const Dictionary &value) { remapped_bones = value; }
    Dictionary get_remapped_bones() const { return remapped_bones; }
    void set_morph_targets_to_copy(const PackedStringArray &value) { morph_targets_to_copy = value; }
    PackedStringArray get_morph_targets_to_copy() const { return morph_targets_to_copy; }
    void set_update_mesh_bounds(bool value) { update_mesh_bounds = value; }
    bool get_update_mesh_bounds() const { return update_mesh_bounds; }
    void set_geometry_mode(int value);
    int get_geometry_mode() const { return geometry_mode; }
    void set_collapse_scale(double value) { collapse_scale = CLAMP(value, 0.0, 0.1); }
    double get_collapse_scale() const { return collapse_scale; }
    void set_weight_threshold(double value) { weight_threshold = CLAMP(value, 0.001, 1.0); }
    double get_weight_threshold() const { return weight_threshold; }
    void set_limb_mass(double value) { limb_mass = MAX(0.001, value); }
    double get_limb_mass() const { return limb_mass; }
    void set_limb_lifetime(double value) { limb_lifetime = MAX(0.0, value); }
    double get_limb_lifetime() const { return limb_lifetime; }
    void set_limb_rigid_fallback_enabled(bool value);
    bool get_limb_rigid_fallback_enabled() const { return limb_rigid_fallback_enabled; }
    void set_limb_collision_layer(uint32_t value) { limb_collision_layer = value; }
    uint32_t get_limb_collision_layer() const { return limb_collision_layer; }
    void set_limb_collision_mask(uint32_t value) { limb_collision_mask = value; }
    uint32_t get_limb_collision_mask() const { return limb_collision_mask; }
    void set_network_enabled(bool value);
    bool get_network_enabled() const { return network_enabled; }
    void set_owning_peer_id(int64_t value) { owning_peer_id = MAX(int64_t(1), value); }
    int64_t get_owning_peer_id() const { return owning_peer_id; }
};

}

VARIANT_ENUM_CAST(godot::DismembermentComponent::GeometryMode);
