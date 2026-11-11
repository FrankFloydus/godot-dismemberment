#include "dismemberment_component.h"
#include "limb_map.h"
#include "mesh_partition.h"

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/bone_attachment3d.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/multiplayer_api.hpp>
#include <godot_cpp/classes/material.hpp>
#include <godot_cpp/classes/physical_bone3d.hpp>
#include <godot_cpp/classes/scene_tree.hpp>
#include <godot_cpp/classes/skin.hpp>
#include <godot_cpp/classes/skin_reference.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/physics_server3d.hpp>
#include <godot_cpp/classes/window.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <set>
#include <map>

namespace godot {

template <class T> static T *resolve(uint64_t id) {
    return id ? Object::cast_to<T>(ObjectDB::get_instance(id)) : nullptr;
}

static void gather_nodes(Node *node, std::vector<Node *> &result) {
    if (!node || node->is_in_group("Dismembered Limb")) return;
    result.push_back(node);
    for (int i = 0; i < node->get_child_count(); ++i) gather_nodes(node->get_child(i), result);
}

static bool contains_bone(Skeleton3D *skeleton, int root, int bone) {
    for (int cursor = bone; cursor >= 0; cursor = skeleton->get_bone_parent(cursor)) {
        if (cursor == root) return true;
    }
    return false;
}

static BoneAttachment3D *attachment_socket(Node *node, Skeleton3D *skeleton) {
    for (Node *parent = node->get_parent(); parent && parent != skeleton; parent = parent->get_parent()) {
        if (BoneAttachment3D *socket = Object::cast_to<BoneAttachment3D>(parent)) return socket;
    }
    return nullptr;
}

static StringName attachment_filter_bone(Node *node, BoneAttachment3D *socket) {
    if (node->has_meta("override_socket")) return node->get_meta("override_socket");
    const Array groups = node->get_groups();
    for (int i = 0; i < groups.size(); ++i) {
        const String group = groups[i];
        if (group.begins_with("OverrideSocket:")) return group.substr(15);
    }
    return socket ? socket->get_bone_name() : StringName();
}

static void replace_mesh_preserving_blends(MeshInstance3D *instance, const Ref<Mesh> &mesh, bool clear_overrides) {
    Dictionary blend_values;
    const Ref<ArrayMesh> original = instance->get_mesh();
    if (original.is_valid()) {
        for (int i = 0; i < original->get_blend_shape_count(); ++i) blend_values[original->get_blend_shape_name(i)] = instance->get_blend_shape_value(i);
    }
    instance->set_mesh(mesh);
    const Ref<ArrayMesh> replacement = mesh;
    if (replacement.is_valid()) {
        for (int i = 0; i < replacement->get_blend_shape_count(); ++i) instance->set_blend_shape_value(i, blend_values.get(replacement->get_blend_shape_name(i), 0.0));
    }
    if (clear_overrides) for (int i = 0; i < instance->get_surface_override_material_count(); ++i) instance->set_surface_override_material(i, Ref<Material>());
}

void DismembermentComponent::_bind_methods() {
    ClassDB::bind_method(D_METHOD("initialize"), &DismembermentComponent::initialize);
    ClassDB::bind_method(D_METHOD("is_system_verified"), &DismembermentComponent::is_system_verified);
    ClassDB::bind_method(D_METHOD("get_last_error"), &DismembermentComponent::get_last_error);
    ClassDB::bind_method(D_METHOD("set_skeletal_mesh_component_to_dismember", "mesh"), &DismembermentComponent::set_skeletal_mesh_component_to_dismember);
    ClassDB::bind_method(D_METHOD("get_skeletal_mesh_component"), &DismembermentComponent::get_skeletal_mesh_component);
    ClassDB::bind_method(D_METHOD("get_skeleton"), &DismembermentComponent::get_skeleton);
    ClassDB::bind_method(D_METHOD("get_all_meshes"), &DismembermentComponent::get_all_meshes);
    ClassDB::bind_method(D_METHOD("get_all_attached_meshes"), &DismembermentComponent::get_all_attached_meshes);
    ClassDB::bind_method(D_METHOD("get_bone_name_options"), &DismembermentComponent::get_bone_name_options);
    ClassDB::bind_method(D_METHOD("get_limb_map"), &DismembermentComponent::get_limb_map);
    ClassDB::bind_method(D_METHOD("check_bone_filter", "bone_name"), &DismembermentComponent::check_bone_filter);
    ClassDB::bind_method(D_METHOD("dismember_limb", "bone_name", "impulse"), &DismembermentComponent::dismember_limb, DEFVAL(Vector3()));
    ClassDB::bind_method(D_METHOD("destroy_limb", "bone_name"), &DismembermentComponent::destroy_limb);
    ClassDB::bind_method(D_METHOD("reset_all_limbs"), &DismembermentComponent::reset_all_limbs);
    ClassDB::bind_method(D_METHOD("clean_up_all_referenced_limbs"), &DismembermentComponent::clean_up_all_referenced_limbs);
    ClassDB::bind_method(D_METHOD("clean_up_referenced_limb", "bone_name"), &DismembermentComponent::clean_up_referenced_limb);
    ClassDB::bind_method(D_METHOD("get_dismembered_limb_by_name", "bone_name"), &DismembermentComponent::get_dismembered_limb_by_name);
    ClassDB::bind_method(D_METHOD("get_all_dismembered_limbs"), &DismembermentComponent::get_all_dismembered_limbs);
    ClassDB::bind_method(D_METHOD("get_dismembered_bones"), &DismembermentComponent::get_dismembered_bones);
    ClassDB::bind_method(D_METHOD("get_replication_state"), &DismembermentComponent::get_replication_state);
    ClassDB::bind_method(D_METHOD("apply_replication_state", "state"), &DismembermentComponent::apply_replication_state);
    ClassDB::bind_method(D_METHOD("synchronize_peer", "peer_id"), &DismembermentComponent::synchronize_peer);
    ClassDB::bind_method(D_METHOD("_finish_dismemberment", "limb_id", "bone_name", "impulse"), &DismembermentComponent::finish_dismemberment);
    ClassDB::bind_method(D_METHOD("_request_dismemberment", "bone_name", "impulse"), &DismembermentComponent::request_dismemberment);
    ClassDB::bind_method(D_METHOD("_receive_dismemberment", "bone_name", "impulse", "revision"), &DismembermentComponent::receive_dismemberment);
    ClassDB::bind_method(D_METHOD("_receive_state", "state"), &DismembermentComponent::receive_state);
    ClassDB::bind_method(D_METHOD("_on_peer_connected", "peer_id"), &DismembermentComponent::on_peer_connected);
    ClassDB::bind_method(D_METHOD("_apply_hidden_skin"), &DismembermentComponent::enforce_hidden_bones);

#define PROPERTY(type, name, hint, hint_string) \
    ClassDB::bind_method(D_METHOD("set_" #name, "value"), &DismembermentComponent::set_##name); \
    ClassDB::bind_method(D_METHOD("get_" #name), &DismembermentComponent::get_##name); \
    ADD_PROPERTY(PropertyInfo(type, #name, hint, hint_string), "set_" #name, "get_" #name)
    ADD_GROUP("Source Rig", "");
    PROPERTY(Variant::NODE_PATH, skeleton_path, PROPERTY_HINT_NODE_PATH_VALID_TYPES, "Skeleton3D");
    PROPERTY(Variant::NODE_PATH, mesh_path, PROPERTY_HINT_NODE_PATH_VALID_TYPES, "MeshInstance3D");
    PROPERTY(Variant::BOOL, override_source_mesh, PROPERTY_HINT_NONE, "");
    PROPERTY(Variant::STRING, source_mesh_component, PROPERTY_HINT_NONE, "");
    PROPERTY(Variant::STRING_NAME, pelvis_bone_name, PROPERTY_HINT_NONE, "");
    PROPERTY(Variant::BOOL, support_attached_child_meshes, PROPERTY_HINT_NONE, "");

    ADD_GROUP("Cut Rules", "");
    PROPERTY(Variant::BOOL, disable_dismemberment, PROPERTY_HINT_NONE, "");
    PROPERTY(Variant::PACKED_STRING_ARRAY, excluded_bones, PROPERTY_HINT_NONE, "");
    PROPERTY(Variant::PACKED_STRING_ARRAY, whitelist_bones, PROPERTY_HINT_NONE, "");
    PROPERTY(Variant::DICTIONARY, remapped_bones, PROPERTY_HINT_NONE, "");

    ADD_GROUP("Cut Geometry", "");
    PROPERTY(Variant::INT, geometry_mode, PROPERTY_HINT_ENUM, "Bone Collapse,Triangle Partition");
    PROPERTY(Variant::FLOAT, collapse_scale, PROPERTY_HINT_RANGE, "0,0.1,0.001");
    PROPERTY(Variant::FLOAT, weight_threshold, PROPERTY_HINT_RANGE, "0.001,1,0.001");
    PROPERTY(Variant::BOOL, update_mesh_bounds, PROPERTY_HINT_NONE, "");
    PROPERTY(Variant::PACKED_STRING_ARRAY, morph_targets_to_copy, PROPERTY_HINT_NONE, "");

    ADD_GROUP("Detached Limbs", "limb_");
    PROPERTY(Variant::FLOAT, limb_lifetime, PROPERTY_HINT_RANGE, "0,3600,0.1,or_greater,suffix:s");
    PROPERTY(Variant::INT, limb_collision_layer, PROPERTY_HINT_LAYERS_3D_PHYSICS, "");
    PROPERTY(Variant::INT, limb_collision_mask, PROPERTY_HINT_LAYERS_3D_PHYSICS, "");
    PROPERTY(Variant::BOOL, limb_rigid_fallback_enabled, PROPERTY_HINT_NONE, "");
    PROPERTY(Variant::FLOAT, limb_mass, PROPERTY_HINT_RANGE, "0.001,1000,0.01,or_greater,suffix:kg");

    ADD_GROUP("Multiplayer", "");
    PROPERTY(Variant::BOOL, network_enabled, PROPERTY_HINT_NONE, "");
    PROPERTY(Variant::INT, owning_peer_id, PROPERTY_HINT_RANGE, "1,2147483647,1");
#undef PROPERTY
    BIND_ENUM_CONSTANT(BONE_COLLAPSE);
    BIND_ENUM_CONSTANT(TRIANGLE_PARTITION);
    ADD_SIGNAL(MethodInfo("pre_dismemberment", PropertyInfo(Variant::STRING_NAME, "bone_name"), PropertyInfo(Variant::VECTOR3, "impulse")));
    ADD_SIGNAL(MethodInfo("post_dismemberment", PropertyInfo(Variant::STRING_NAME, "bone_name"), PropertyInfo(Variant::OBJECT, "limb", PROPERTY_HINT_NODE_TYPE, "DismemberedLimb")));
    ADD_SIGNAL(MethodInfo("limbs_reset"));
    ADD_SIGNAL(MethodInfo("replication_state_changed", PropertyInfo(Variant::DICTIONARY, "state")));
}

void DismembermentComponent::_validate_property(PropertyInfo &p_property) const {
    const String name = p_property.name;
    const bool explicit_mesh = !mesh_path.is_empty();
    const bool partition = geometry_mode == TRIANGLE_PARTITION;
    if ((name == "override_source_mesh" && explicit_mesh) ||
            (name == "source_mesh_component" && (explicit_mesh || !override_source_mesh)) ||
            (name == "collapse_scale" && partition) ||
            (name == "weight_threshold" && !partition && !limb_rigid_fallback_enabled) ||
            (name == "update_mesh_bounds" && !partition) ||
            (name == "limb_mass" && !limb_rigid_fallback_enabled) ||
            (name == "owning_peer_id" && !network_enabled)) {
        p_property.usage &= ~PROPERTY_USAGE_EDITOR;
    }
}

void DismembermentComponent::set_mesh_path(const NodePath &value) {
    const bool had_automatic_mesh = mesh_path.is_empty();
    mesh_path = value;
    initialized = false;
    if (had_automatic_mesh != mesh_path.is_empty()) notify_property_list_changed();
}

void DismembermentComponent::set_override_source_mesh(bool value) {
    const bool changed = override_source_mesh != value;
    override_source_mesh = value;
    initialized = false;
    if (changed) notify_property_list_changed();
}

void DismembermentComponent::set_geometry_mode(int value) {
    const int mode = CLAMP(value, 0, 1);
    if (!missing_limbs.is_empty() || geometry_mode == mode) return;
    geometry_mode = mode;
    notify_property_list_changed();
}

void DismembermentComponent::set_limb_rigid_fallback_enabled(bool value) {
    if (limb_rigid_fallback_enabled == value) return;
    limb_rigid_fallback_enabled = value;
    notify_property_list_changed();
}

void DismembermentComponent::set_network_enabled(bool value) {
    if (network_enabled == value) return;
    network_enabled = value;
    notify_property_list_changed();
}

DismembermentComponent::DismembermentComponent() {
    set_process(false);
    set_physics_process(false);
    set_process_priority(1000);
}

void DismembermentComponent::_process(double) { enforce_hidden_bones(); }
void DismembermentComponent::_physics_process(double) { enforce_hidden_bones(); }

void DismembermentComponent::enforce_hidden_bones() {
    if (hidden_bone_scales.is_empty()) return;
    Skeleton3D *skeleton = get_skeleton();
    if (!skeleton) return;
    hide_source_attachments();
    if (geometry_mode != BONE_COLLAPSE) return;
    const Array roots = hidden_bone_scales.keys();
    const TypedArray<MeshInstance3D> meshes = get_all_meshes();
    RenderingServer *renderer = RenderingServer::get_singleton();
    for (int m = 0; m < meshes.size(); ++m) {
        MeshInstance3D *mesh = Object::cast_to<MeshInstance3D>(meshes[m]);
        if (!mesh) continue;
        const Ref<SkinReference> reference = mesh->get_skin_reference();
        if (reference.is_null() || !reference->get_skeleton().is_valid()) continue;
        const Ref<Skin> skin = reference->get_skin();
        if (skin.is_null()) continue;
        if (renderer->skeleton_get_bone_count(reference->get_skeleton()) < skin->get_bind_count()) continue;
        for (int bind = 0; bind < skin->get_bind_count(); ++bind) {
            const StringName name = skin->get_bind_name(bind);
            const int bone = name != StringName() ? skeleton->find_bone(name) : skin->get_bind_bone(bind);
            if (bone < 0 || bone >= skeleton->get_bone_count()) continue;
            int collapsed_root = -1;
            for (int r = 0; r < roots.size(); ++r) {
                const int root = skeleton->find_bone(roots[r]);
                if (root < 0 || !contains_bone(skeleton, root, bone)) continue;
                if (collapsed_root < 0 || contains_bone(skeleton, root, collapsed_root)) collapsed_root = root;
            }
            if (collapsed_root >= 0) {
                Transform3D collapsed;
                collapsed.basis = Basis(Vector3(), Vector3(), Vector3());
                const StringName root_name = skeleton->get_bone_name(collapsed_root);
                const Transform3D local = hidden_bone_local_poses.get(root_name, skeleton->get_bone_pose(collapsed_root));
                const int parent = skeleton->get_bone_parent(collapsed_root);
                collapsed.origin = parent >= 0 ? (evaluated_bone_pose(skeleton, mesh, parent) * local).origin : local.origin;
                // Hide after the fully evaluated animation/IK/physics pose has
                // been uploaded. Editing local pose scale is insufficient when
                // a procedural global override supplies the final bone matrix.
                renderer->skeleton_bone_set_transform(reference->get_skeleton(), bind, collapsed * skin->get_bind_pose(bind));
            }
        }
    }
}

void DismembermentComponent::hide_source_attachments() {
    Skeleton3D *skeleton = get_skeleton();
    if (!skeleton || hidden_bone_scales.is_empty()) return;
    std::vector<Node *> nodes;
    gather_nodes(skeleton, nodes);
    const Array roots = hidden_bone_scales.keys();
    for (Node *node : nodes) {
        BoneAttachment3D *attachment = Object::cast_to<BoneAttachment3D>(node);
        if (!attachment) continue;
        if (attachment->get_use_external_skeleton()) {
            if (attachment->get_node_or_null(attachment->get_external_skeleton()) != skeleton) continue;
        } else {
            Skeleton3D *owner_skeleton = nullptr;
            for (Node *parent = attachment->get_parent(); parent && !owner_skeleton; parent = parent->get_parent()) owner_skeleton = Object::cast_to<Skeleton3D>(parent);
            if (owner_skeleton != skeleton) continue;
        }
        const int bone = skeleton->find_bone(attachment->get_bone_name());
        if (bone < 0) continue;
        bool hidden = false;
        for (int i = 0; i < roots.size(); ++i) {
            const int root = skeleton->find_bone(roots[i]);
            if (root >= 0 && contains_bone(skeleton, root, bone)) { hidden = true; break; }
        }
        if (!hidden) continue;
        const uint64_t id = uint64_t(attachment->get_instance_id());
        bool cached = false;
        for (const AttachmentVisibilityState &state : attachment_visibility) if (state.id == id) { cached = true; break; }
        if (!cached) attachment_visibility.push_back({id, attachment->is_visible()});
        attachment->set_visible(false);
    }
}

void DismembermentComponent::_ready() {
    configure_rpc();
    RenderingServer *renderer = RenderingServer::get_singleton();
    const Callable callback(this, "_apply_hidden_skin");
    if (!renderer->is_connected("frame_pre_draw", callback)) renderer->connect("frame_pre_draw", callback);
    if (!Engine::get_singleton()->is_editor_hint()) call_deferred("initialize");
}

void DismembermentComponent::_exit_tree() {
    if (Node *quarantine = resolve<Node>(physics_quarantine_id)) quarantine->queue_free();
    physics_quarantine_id = 0;
}

void DismembermentComponent::configure_rpc() {
    Dictionary request;
    request["rpc_mode"] = MultiplayerAPI::RPC_MODE_ANY_PEER;
    request["call_local"] = false;
    request["transfer_mode"] = 2; // reliable commands, state retained for late joiners
    rpc_config("_request_dismemberment", request);
    Dictionary receive = request.duplicate(true);
    receive["rpc_mode"] = MultiplayerAPI::RPC_MODE_AUTHORITY;
    rpc_config("_receive_dismemberment", receive);
    rpc_config("_receive_state", receive);
    if (is_inside_tree()) {
        Ref<MultiplayerAPI> api = get_multiplayer();
        Callable callback(this, "_on_peer_connected");
        if (api.is_valid() && !api->is_connected("peer_connected", callback)) api->connect("peer_connected", callback);
    }
}

MeshInstance3D *DismembermentComponent::get_skeletal_mesh_component() const { return resolve<MeshInstance3D>(mesh_id); }
Skeleton3D *DismembermentComponent::get_skeleton() const { return resolve<Skeleton3D>(skeleton_id); }

void DismembermentComponent::set_skeletal_mesh_component_to_dismember(MeshInstance3D *mesh) {
    if (!missing_limbs.is_empty()) reset_all_limbs();
    mesh_id = mesh ? uint64_t(mesh->get_instance_id()) : 0;
    set_mesh_path(mesh && is_inside_tree() ? get_path_to(mesh) : NodePath());
}

bool DismembermentComponent::initialize() {
    if (initialized && get_skeleton() && get_skeletal_mesh_component()) return true;
    last_error = "";
    std::vector<Node *> nodes;
    gather_nodes(get_parent() ? get_parent() : this, nodes);
    Skeleton3D *skeleton = skeleton_path.is_empty() ? nullptr : Object::cast_to<Skeleton3D>(get_node_or_null(skeleton_path));
    MeshInstance3D *mesh = mesh_path.is_empty() ? get_skeletal_mesh_component() : Object::cast_to<MeshInstance3D>(get_node_or_null(mesh_path));
    if (!mesh) {
        for (Node *node : nodes) {
            MeshInstance3D *candidate = Object::cast_to<MeshInstance3D>(node);
            if (candidate && candidate->is_in_group("Dismemberment Source")) { mesh = candidate; break; }
        }
    }
    if (!mesh) {
        for (Node *node : nodes) {
            MeshInstance3D *candidate = Object::cast_to<MeshInstance3D>(node);
            if (!candidate || candidate->get_mesh().is_null()) continue;
            if (override_source_mesh && candidate->get_name() != source_mesh_component) continue;
            if (candidate->get_skin().is_valid() || override_source_mesh) { mesh = candidate; break; }
        }
    }
    if (!skeleton && mesh && !mesh->get_skeleton_path().is_empty()) skeleton = Object::cast_to<Skeleton3D>(mesh->get_node_or_null(mesh->get_skeleton_path()));
    if (!skeleton) for (Node *node : nodes) if ((skeleton = Object::cast_to<Skeleton3D>(node))) break;
    if (!mesh || mesh->get_mesh().is_null()) last_error = "No source skinned MeshInstance3D found. Set mesh_path or the Dismemberment Source group.";
    else if (!skeleton || skeleton->get_bone_count() == 0) last_error = "No nonempty Skeleton3D found. Set skeleton_path.";
    else if (String(pelvis_bone_name).is_empty() || skeleton->find_bone(pelvis_bone_name) < 0) last_error = "pelvis_bone_name must identify a bone in the source Skeleton3D.";
    if (!last_error.is_empty()) { initialized = false; return false; }
    skeleton_id = uint64_t(skeleton->get_instance_id());
    mesh_id = uint64_t(mesh->get_instance_id());
    if (missing_limbs.is_empty()) {
        source_states.clear();
        source_states.push_back({mesh_id, mesh->get_mesh(), mesh->get_custom_aabb()});
        if (support_attached_child_meshes) {
            for (Node *node : nodes) {
                MeshInstance3D *candidate = Object::cast_to<MeshInstance3D>(node);
                if (!candidate || candidate == mesh || candidate->get_skin().is_null()) continue;
                Skeleton3D *candidate_skeleton = Object::cast_to<Skeleton3D>(candidate->get_node_or_null(candidate->get_skeleton_path()));
                if (candidate_skeleton == skeleton) source_states.push_back({uint64_t(candidate->get_instance_id()), candidate->get_mesh(), candidate->get_custom_aabb()});
            }
        }
        // Skeleton3D reuses a renderer SkinReference for identical Skin resources.
        // Give each participating source its own runtime binding so hiding one
        // component cannot hide an excluded garment or another source component.
        for (MeshState &state : source_states) {
            MeshInstance3D *source = resolve<MeshInstance3D>(state.id);
            if (!source) continue;
            for (int surface = 0; surface < source->get_surface_override_material_count(); ++surface) {
                state.original_surface_overrides.push_back(source->get_surface_override_material(surface));
            }
            Ref<Skin> source_skin = source->get_skin();
            if (source_skin.is_null()) {
                const Ref<SkinReference> reference = source->get_skin_reference();
                if (reference.is_valid()) source_skin = reference->get_skin();
            }
            if (source_skin.is_valid()) source->set_skin(source_skin->duplicate());
        }
    }
    limb_map.instantiate();
    limb_map->initialize(skeleton, mesh);
    initialized = true;
    return true;
}

TypedArray<MeshInstance3D> DismembermentComponent::get_all_meshes() const {
    TypedArray<MeshInstance3D> result;
    for (const MeshState &state : source_states) if (MeshInstance3D *mesh = resolve<MeshInstance3D>(state.id)) result.push_back(mesh);
    if (result.is_empty() && get_skeletal_mesh_component()) result.push_back(get_skeletal_mesh_component());
    return result;
}

TypedArray<MeshInstance3D> DismembermentComponent::get_all_attached_meshes() const {
    TypedArray<MeshInstance3D> result;
    const TypedArray<MeshInstance3D> meshes = get_all_meshes();
    for (int i = 0; i < meshes.size(); ++i) if (Object::cast_to<MeshInstance3D>(meshes[i]) != get_skeletal_mesh_component()) result.push_back(meshes[i]);
    return result;
}

PackedStringArray DismembermentComponent::get_bone_name_options() const {
    PackedStringArray result;
    Skeleton3D *skeleton = get_skeleton();
    if (!skeleton) return result;
    for (int i = 0; i < skeleton->get_bone_count(); ++i) result.push_back(skeleton->get_bone_name(i));
    return result;
}

Ref<LimbMap> DismembermentComponent::get_limb_map() const { return limb_map; }

bool DismembermentComponent::check_bone_filter(const StringName &bone_name) const {
    return !excluded_bones.has(String(bone_name)) && (whitelist_bones.is_empty() || whitelist_bones.has(String(bone_name)));
}

bool DismembermentComponent::validate_bone(const StringName &bone_name) const {
    Skeleton3D *skeleton = get_skeleton();
    return skeleton && skeleton->find_bone(bone_name) >= 0 && !String(bone_name).begins_with("VB");
}

void DismembermentComponent::pre_dismemberment(const StringName &bone_name, const Vector3 &impulse) { emit_signal("pre_dismemberment", bone_name, impulse); }
void DismembermentComponent::post_dismemberment(const StringName &bone_name, DismemberedLimb *limb) { emit_signal("post_dismemberment", bone_name, limb); }

void DismembermentComponent::dismember_limb(const StringName &bone_name, const Vector3 &impulse) {
    if (!impulse.is_finite() || impulse.length_squared() > 1.0e12) return;
    if (!initialized && !initialize()) return;
    if (network_enabled && is_inside_tree() && get_multiplayer()->has_multiplayer_peer() && !is_multiplayer_authority()) {
        rpc_id(get_multiplayer_authority(), "_request_dismemberment", bone_name, impulse);
        return;
    }
    const int before = dismembered_bones.size();
    dismember_internal(bone_name, impulse);
    if (before == dismembered_bones.size()) return;
    ++replication_revision;
    emit_signal("replication_state_changed", get_replication_state());
    if (network_enabled && is_inside_tree() && get_multiplayer()->has_multiplayer_peer()) rpc("_receive_dismemberment", bone_name, impulse, replication_revision);
}

void DismembermentComponent::dismember_internal(const StringName &input_bone, const Vector3 &impulse, bool canonical) {
    StringName bone_name = canonical ? input_bone : StringName(remapped_bones.get(input_bone, input_bone));
    if (disable_dismemberment || !validate_bone(bone_name) || !check_bone_filter(bone_name) || missing_limbs.has(bone_name)) return;
    Skeleton3D *skeleton = get_skeleton();
    pre_dismemberment(bone_name, impulse);
    const int bone = skeleton->find_bone(bone_name);
    const Transform3D cut_pose = evaluated_bone_pose(skeleton, get_skeletal_mesh_component(), bone);
    const int cut_parent = skeleton->get_bone_parent(bone);
    const Transform3D cut_local_pose = cut_parent >= 0 ? evaluated_bone_pose(skeleton, get_skeletal_mesh_component(), cut_parent).affine_inverse() * cut_pose : cut_pose;
    const Transform3D cut_transform = skeleton->get_global_transform() * cut_pose;
    DismemberedLimb *limb = memnew(DismemberedLimb);
    limb->set_name(String("Limb_") + String(bone_name));
    limb->set_bone_name(bone_name);
    limb->set_bone_transform(cut_transform);
    limb->set_mass(limb_mass);
    limb->set_lifetime(limb_lifetime);
    limb->set_rigid_fallback_enabled(limb_rigid_fallback_enabled);
    limb->set_freeze_enabled(true);
    limb->set_collision_layer(limb_collision_layer);
    limb->set_collision_mask(limb_collision_mask);
    Ref<DismemberedAnimInstance> animation;
    animation.instantiate();
    animation->set_limb(bone_name);
    animation->set_pelvis_bone_name(pelvis_bone_name);
    animation->capture_pose(skeleton);
    limb->set_anim_instance(animation);
    Node *world = get_tree() ? get_tree()->get_current_scene() : nullptr;
    if (!world || world == this) world = get_parent();
    if (!world) world = this;
    world->add_child(limb);
    // Physics objects require a nonscaled basis. Bake all component/bone scaling
    // into mesh and collision coordinates instead of applying it twice.
    Transform3D body_transform(cut_transform.basis.orthonormalized(), cut_transform.origin);
    limb->set_global_transform(body_transform);
    PackedStringArray all_missing;
    const Array missing_keys = missing_limbs.keys();
    for (int i = 0; i < missing_keys.size(); ++i) all_missing.push_back(missing_keys[i]);
    limb->prepare_pose_skeleton(skeleton, get_skeletal_mesh_component());
    const bool articulated = limb->prepare_articulated_physics(skeleton, bone_name, all_missing, limb_collision_layer, limb_collision_mask);
    if (geometry_mode == BONE_COLLAPSE) {
        limb->prepare_pose_skeleton(skeleton);
        limb->collapse_complement(bone_name, collapse_scale);
        PackedStringArray previous_roots = dismembered_bones;
        for (int i = 0; i < destroyed_bones.size(); ++i) previous_roots.push_back(destroyed_bones[i]);
        limb->set_hidden_bone_roots(previous_roots);
    }
    const bool partition_geometry = geometry_mode == TRIANGLE_PARTITION;
    const bool needs_fallback_collision = !articulated && limb_rigid_fallback_enabled;
    const TypedArray<MeshInstance3D> meshes = get_all_meshes();
    for (int i = 0; i < meshes.size(); ++i) {
        MeshInstance3D *source = Object::cast_to<MeshInstance3D>(meshes[i]);
        if (!source || source->get_mesh().is_null()) continue;
        Ref<ArrayMesh> detached;
        // Bone Collapse renders the full skin. It only needs partitioned
        // geometry when constructing a fallback collider.
        if (partition_geometry || needs_fallback_collision) {
            const Ref<ArrayMesh> source_resource = source->get_mesh();
            Dictionary live_morphs;
            if (source_resource.is_valid()) {
                for (int blend = 0; blend < source_resource->get_blend_shape_count(); ++blend) {
                    const StringName blend_name = source_resource->get_blend_shape_name(blend);
                    live_morphs[blend_name] = source->get_blend_shape_value(blend);
                    if (!articulated && !morph_targets_to_copy.has(blend_name)) source->set_blend_shape_value(blend, 0.0);
                }
            }
            const Dictionary partition = MeshPartition::isolate_limb(source, skeleton, bone_name, weight_threshold, !articulated);
            if (source_resource.is_valid()) {
                for (int blend = 0; blend < source_resource->get_blend_shape_count(); ++blend) {
                    source->set_blend_shape_value(blend, live_morphs.get(source_resource->get_blend_shape_name(blend), 0.0));
                }
            }
            const Ref<ArrayMesh> remaining = partition.get("remaining_mesh", Ref<ArrayMesh>());
            detached = partition.get("detached_mesh", Ref<ArrayMesh>());
            if (remaining.is_valid() && partition_geometry) {
                replace_mesh_preserving_blends(source, remaining, true);
                for (const MeshState &state : source_states) if (state.id == uint64_t(source->get_instance_id())) {
                    source->set_custom_aabb(update_mesh_bounds ? AABB() : (state.original_custom_aabb.has_surface() ? state.original_custom_aabb : state.original->get_aabb()));
                    break;
                }
            }
        }
        // Source EnGore hides supported child skin even with this tag; the tag
        // suppresses its detached copy, rather than keeping source skin visible.
        if (source != get_skeletal_mesh_component()) {
            if (source->is_in_group("No Dismemberment")) continue;
            const StringName filter_bone = attachment_filter_bone(source, attachment_socket(source, skeleton));
            if (filter_bone != StringName() && !contains_bone(skeleton, bone, skeleton->find_bone(filter_bone))) continue;
        }
        if (geometry_mode == BONE_COLLAPSE) {
            if (needs_fallback_collision && detached.is_valid()) limb->add_collision_mesh(detached, source->get_global_transform());
            detached = source->get_mesh()->duplicate();
            if (detached.is_valid()) {
                for (int s = 0; s < detached->get_surface_count(); ++s) detached->surface_set_material(s, source->get_active_material(s));
            }
        }
        if (detached.is_null() || detached->get_surface_count() == 0) continue;
        MeshInstance3D *piece = memnew(MeshInstance3D);
        piece->set_name(source->get_name());
        piece->set_mesh(detached);
        piece->set_material_override(source->get_material_override());
        piece->set_material_overlay(source->get_material_overlay());
        piece->set_cast_shadows_setting(source->get_cast_shadows_setting());
        piece->set_gi_mode(source->get_gi_mode());
        limb->add_child(piece);
        piece->set_global_transform(source->get_global_transform());
        if (articulated || geometry_mode == BONE_COLLAPSE) {
            piece->set_skin(source->get_skin());
            piece->set_skeleton_path(piece->get_path_to(limb->get_ragdoll_skeleton()));
            for (int blend = 0; blend < detached->get_blend_shape_count(); ++blend) {
                const int source_blend = source->find_blend_shape_by_name(detached->get_blend_shape_name(blend));
                if (source_blend >= 0 && morph_targets_to_copy.has(detached->get_blend_shape_name(blend))) piece->set_blend_shape_value(blend, source->get_blend_shape_value(source_blend));
            }
        }
        for (int s = 0; s < detached->get_surface_count(); ++s) {
            Ref<Material> material = detached->surface_get_material(s);
            if (material.is_valid()) detached->surface_set_material(s, material->duplicate());
        }
    }
    transfer_attachments(bone_name, limb);
    if (needs_fallback_collision) limb->build_collision();
    disable_missing_physics(bone_name);
    hidden_bone_scales[bone_name] = skeleton->get_bone_pose_scale(bone);
    hidden_bone_local_poses[bone_name] = cut_local_pose;
    if (geometry_mode == BONE_COLLAPSE) {
        set_process(true);
        set_physics_process(true);
        enforce_hidden_bones();
    } else hide_source_attachments();
    for (int i = 0; i < skeleton->get_bone_count(); ++i) {
        const StringName name = skeleton->get_bone_name(i);
        if (contains_bone(skeleton, bone, i) && !missing_limbs.has(name)) missing_limbs[name] = uint64_t(limb->get_instance_id());
    }
    dismembered_bones.push_back(bone_name);
    Dictionary cut_event;
    cut_event["bone"] = bone_name;
    cut_event["destroy"] = false;
    dismemberment_events.push_back(cut_event);
    call_deferred("_finish_dismemberment", uint64_t(limb->get_instance_id()), bone_name, impulse);
}

void DismembermentComponent::finish_dismemberment(uint64_t id, const StringName &bone_name, const Vector3 &impulse) {
    DismemberedLimb *limb = resolve<DismemberedLimb>(id);
    if (!limb || limb->is_queued_for_deletion()) return;
    limb->begin_simulation(impulse);
    limb->set_physics_process(limb->get_lifetime() > 0.0);
    post_dismemberment(bone_name, limb);
}

void DismembermentComponent::transfer_attachments(const StringName &bone_name, DismemberedLimb *limb) {
    if (!support_attached_child_meshes) return;
    Skeleton3D *skeleton = get_skeleton();
    const int root = skeleton->find_bone(bone_name);
    std::vector<Node *> nodes;
    gather_nodes(skeleton, nodes);
    for (Node *node : nodes) {
        Node3D *attachment = Object::cast_to<Node3D>(node);
        if (!attachment || !attachment->get_parent() || !attachment->is_in_group("Transfer Dismemberment") || attachment->is_in_group("No Dismemberment")) continue;
        BoneAttachment3D *source_socket = attachment_socket(attachment, skeleton);
        const StringName filter_bone = attachment_filter_bone(attachment, source_socket);
        if (!contains_bone(skeleton, root, skeleton->find_bone(filter_bone))) continue;
        Node *original_parent = attachment->get_parent();
        const Transform3D original_transform = attachment->get_transform();
        transferred_nodes.push_back({uint64_t(attachment->get_instance_id()), uint64_t(original_parent->get_instance_id()), original_transform});
        Skeleton3D *ragdoll = limb->get_ragdoll_skeleton();
        const bool has_authored_socket = source_socket && skeleton->find_bone(source_socket->get_bone_name()) >= 0;
        if (ragdoll) {
            // OverrideSocket filters the cut. The transferred object still
            // uses its authored socket and socket-relative offset when present.
            BoneAttachment3D *socket = memnew(BoneAttachment3D);
            socket->set_bone_name(has_authored_socket ? source_socket->get_bone_name() : filter_bone);
            ragdoll->add_child(socket);
            if (!has_authored_socket || attachment->is_set_as_top_level()) {
                attachment->reparent(socket, true);
            } else {
                const Transform3D socket_offset = original_parent == source_socket ? original_transform : source_socket->get_global_transform().affine_inverse() * attachment->get_global_transform();
                attachment->reparent(socket, false);
                attachment->set_transform(socket_offset);
            }
        } else attachment->reparent(limb, true);
    }
}

void DismembermentComponent::disable_missing_physics(const StringName &bone_name) {
    Skeleton3D *skeleton = get_skeleton();
    if (!skeleton) return;
    std::vector<Node *> nodes;
    gather_nodes(skeleton, nodes);
    const int root = skeleton->find_bone(bone_name);
    std::map<uint64_t, Node *> owners;
    std::map<uint64_t, TypedArray<StringName>> initial;
    std::map<uint64_t, TypedArray<StringName>> surviving;
    std::set<uint64_t> affected;
    std::vector<PhysicalBone3D *> removed;
    struct LiveBody { PhysicalBone3D *body; Transform3D world; Vector3 linear; Vector3 angular; };
    std::vector<LiveBody> live_survivors;
    for (Node *node : nodes) {
        PhysicalBone3D *physical = Object::cast_to<PhysicalBone3D>(node);
        if (!physical || physical->get_bone_id() < 0) continue;
        Node *owner = skeleton;
        for (Node *parent = physical->get_parent(); parent && parent != skeleton; parent = parent->get_parent()) {
            if (parent->is_class("PhysicalBoneSimulator3D")) { owner = parent; break; }
        }
        const uint64_t owner_id = uint64_t(owner->get_instance_id());
        owners[owner_id] = owner;
        const StringName name = skeleton->get_bone_name(physical->get_bone_id());
        const bool selected = contains_bone(skeleton, root, physical->get_bone_id());
        if (physical->is_simulating_physics()) {
            initial[owner_id].push_back(name);
            if (!selected && !missing_limbs.has(name)) {
                surviving[owner_id].push_back(name);
                live_survivors.push_back({physical, physical->get_global_transform(), physical->get_linear_velocity(), physical->get_angular_velocity()});
            }
        }
        if (!selected) continue;
        affected.insert(owner_id);
        removed.push_back(physical);
        Node3D *parent_3d = Object::cast_to<Node3D>(physical->get_parent());
        const Transform3D parent_local = parent_3d ? parent_3d->get_global_transform().affine_inverse() * physical->get_global_transform() : physical->get_global_transform();
        source_physics_states.push_back({uint64_t(physical->get_instance_id()), uint64_t(physical->get_parent()->get_instance_id()), physical->get_index(), parent_local});
        // Preserve collision state for reset without modifying the imported asset.
        if (!physical->has_meta("_godot_dismemberment_original_layer")) {
            physical->set_meta("_godot_dismemberment_original_layer", physical->get_collision_layer());
            physical->set_meta("_godot_dismemberment_original_mask", physical->get_collision_mask());
        }
        physical->set_collision_layer(0);
        physical->set_collision_mask(0);
    }
    for (const auto &entry : owners) {
        bool cached = false;
        for (const SourceSimulatorState &state : source_simulator_states) if (state.id == entry.first) { cached = true; break; }
        if (!cached) source_simulator_states.push_back({entry.first, initial[entry.first]});
    }
    for (uint64_t id : affected) owners[id]->call("physical_bones_stop_simulation");
    if (!removed.empty()) {
        Node3D *quarantine = resolve<Node3D>(physics_quarantine_id);
        if (!quarantine && is_inside_tree()) {
            quarantine = memnew(Node3D);
            quarantine->set_name("DisabledDismembermentPhysics");
            quarantine->set_visible(false);
            get_tree()->get_root()->add_child(quarantine);
            physics_quarantine_id = uint64_t(quarantine->get_instance_id());
        }
        if (quarantine) for (PhysicalBone3D *physical : removed) {
            // Godot start_simulation([Hips]) activates every descendant. Merely
            // clearing collision masks leaves missing bodies and their joints
            // alive. Exit the source skeleton to unbind them before gameplay
            // can start the remaining ragdoll, matching source PhysicsAsset trim.
            physical->reparent(quarantine, true);
            PhysicsServer3D::get_singleton()->body_set_mode(physical->get_rid(), PhysicsServer3D::BODY_MODE_STATIC);
        }
    }
    for (uint64_t id : affected) {
        if (!surviving[id].is_empty()) owners[id]->call("physical_bones_start_simulation", surviving[id]);
    }
    for (const LiveBody &state : live_survivors) {
        state.body->set_global_transform(state.world);
        state.body->set_linear_velocity(state.linear);
        state.body->set_angular_velocity(state.angular);
    }
}

void DismembermentComponent::hide_internal(const StringName &bone_name) {
    Skeleton3D *skeleton = get_skeleton();
    if (!skeleton || !validate_bone(bone_name) || missing_limbs.has(bone_name)) return;
    const int root = skeleton->find_bone(bone_name);
    const int parent = skeleton->get_bone_parent(root);
    const Transform3D cut_pose = evaluated_bone_pose(skeleton, get_skeletal_mesh_component(), root);
    hidden_bone_local_poses[bone_name] = parent >= 0 ? evaluated_bone_pose(skeleton, get_skeletal_mesh_component(), parent).affine_inverse() * cut_pose : cut_pose;
    TypedArray<MeshInstance3D> meshes = get_all_meshes();
    for (int i = 0; i < meshes.size(); ++i) {
        MeshInstance3D *source = Object::cast_to<MeshInstance3D>(meshes[i]);
        if (!source) continue;
        if (geometry_mode == TRIANGLE_PARTITION) {
            const Dictionary partition = MeshPartition::isolate_limb(source, skeleton, bone_name, weight_threshold, false);
            Ref<ArrayMesh> remaining = partition.get("remaining_mesh", Ref<ArrayMesh>());
            if (remaining.is_valid()) replace_mesh_preserving_blends(source, remaining, true);
        }
    }
    hidden_bone_scales[bone_name] = skeleton->get_bone_pose_scale(root);
    if (geometry_mode == BONE_COLLAPSE) {
        set_process(true);
        set_physics_process(true);
        enforce_hidden_bones();
    } else hide_source_attachments();
    for (int i = 0; i < skeleton->get_bone_count(); ++i) if (contains_bone(skeleton, root, i) && !missing_limbs.has(skeleton->get_bone_name(i))) missing_limbs[skeleton->get_bone_name(i)] = uint64_t(0);
    disable_missing_physics(bone_name);
    destroyed_bones.push_back(bone_name);
    Dictionary destroy_event;
    destroy_event["bone"] = bone_name;
    destroy_event["destroy"] = true;
    dismemberment_events.push_back(destroy_event);
}

void DismembermentComponent::destroy_limb(const StringName &input_bone) {
    if (!initialized && !initialize()) return;
    if (network_enabled && is_inside_tree() && get_multiplayer()->has_multiplayer_peer() && !is_multiplayer_authority()) return;
    const StringName bone_name = remapped_bones.get(input_bone, input_bone);
    if (disable_dismemberment || !check_bone_filter(bone_name)) return;
    const int before = destroyed_bones.size();
    hide_internal(bone_name);
    if (before != destroyed_bones.size()) {
        ++replication_revision;
        emit_signal("replication_state_changed", get_replication_state());
        if (network_enabled && is_inside_tree() && get_multiplayer()->has_multiplayer_peer()) rpc("_receive_state", get_replication_state());
    }
}

DismemberedLimb *DismembermentComponent::get_dismembered_limb_by_name(const StringName &bone_name) const {
    return resolve<DismemberedLimb>(missing_limbs.get(bone_name, uint64_t(0)));
}

TypedArray<DismemberedLimb> DismembermentComponent::get_all_dismembered_limbs() const {
    TypedArray<DismemberedLimb> result;
    const Array keys = missing_limbs.keys();
    std::set<uint64_t> visited;
    for (int i = 0; i < keys.size(); ++i) {
        const uint64_t id = missing_limbs[keys[i]];
        if (!id || !visited.insert(id).second) continue;
        if (DismemberedLimb *limb = resolve<DismemberedLimb>(id)) if (!limb->is_queued_for_deletion()) result.push_back(limb);
    }
    return result;
}

void DismembermentComponent::restore_attachments() {
    for (const TransferState &state : transferred_nodes) {
        Node3D *node = resolve<Node3D>(state.id);
        Node *parent = resolve<Node>(state.parent_id);
        if (!node || !parent || node->is_queued_for_deletion()) continue;
        node->reparent(parent, false);
        node->set_transform(state.transform);
    }
    transferred_nodes.clear();
}

void DismembermentComponent::clean_up_referenced_limb(const StringName &bone_name) {
    if (DismemberedLimb *limb = get_dismembered_limb_by_name(bone_name)) limb->queue_free();
}

void DismembermentComponent::clean_up_all_referenced_limbs() {
    TypedArray<DismemberedLimb> limbs = get_all_dismembered_limbs();
    for (int i = 0; i < limbs.size(); ++i) {
        DismemberedLimb *limb = Object::cast_to<DismemberedLimb>(limbs[i]);
        if (limb) limb->queue_free();
    }
}

void DismembermentComponent::reset_all_limbs() {
    Skeleton3D *source_skeleton = get_skeleton();
    bool resume_simulation = false;
    for (const SourceSimulatorState &state : source_simulator_states) if (!state.simulated_bones.is_empty()) resume_simulation = true;
    std::vector<Transform3D> reset_poses;
    if (source_skeleton) for (int bone = 0; bone < source_skeleton->get_bone_count(); ++bone) {
        reset_poses.push_back(resume_simulation ? evaluated_bone_pose(source_skeleton, get_skeletal_mesh_component(), bone) : source_skeleton->get_bone_global_pose(bone));
    }
    struct ResetBody {
        PhysicalBone3D *body;
        PhysicalBone3D::JointType joint_type;
        Transform3D joint_offset;
        Dictionary constraints;
        Transform3D world;
        Vector3 linear;
        Vector3 angular;
    };
    std::vector<ResetBody> reset_bodies;
    std::set<uint64_t> body_ids;
    std::vector<Node *> original_nodes;
    if (source_skeleton) gather_nodes(source_skeleton, original_nodes);
    for (const SourcePhysicsState &state : source_physics_states) if (Node *node = resolve<Node>(state.id)) original_nodes.push_back(node);
    for (Node *node : original_nodes) {
        PhysicalBone3D *body = Object::cast_to<PhysicalBone3D>(node);
        if (!body || !source_skeleton || !body_ids.insert(uint64_t(body->get_instance_id())).second) continue;
        const StringName name = body->get("bone_name");
        const int bone = source_skeleton->find_bone(name);
        if (bone < 0 || bone >= int(reset_poses.size())) continue;
        Dictionary constraints;
        const Array properties = body->get_property_list();
        for (int p = 0; p < properties.size(); ++p) {
            const Dictionary property = properties[p];
            const String property_name = property.get("name", "");
            if (property_name.begins_with("joint_constraints/")) constraints[property_name] = body->get(property_name);
        }
        reset_bodies.push_back({body, body->get_joint_type(), body->get_joint_offset(), constraints,
            (source_skeleton->get_global_transform() * reset_poses[bone] * body->get_body_offset()).orthonormalized(),
            body->get_linear_velocity(), body->get_angular_velocity()});
    }
    restore_attachments();
    for (const AttachmentVisibilityState &state : attachment_visibility) if (Node3D *attachment = resolve<Node3D>(state.id)) attachment->set_visible(state.visible);
    attachment_visibility.clear();
    clean_up_all_referenced_limbs();
    for (const SourceSimulatorState &state : source_simulator_states) if (Node *owner = resolve<Node>(state.id)) owner->call("physical_bones_stop_simulation");
    // Rebinding a child creates its parent constraint immediately. Remove all
    // joints first so a standing restored child cannot bind to a fallen parent.
    for (const ResetBody &state : reset_bodies) state.body->set_joint_type(PhysicalBone3D::JOINT_TYPE_NONE);
    for (const SourcePhysicsState &state : source_physics_states) {
        PhysicalBone3D *body = resolve<PhysicalBone3D>(state.id);
        Node *parent = resolve<Node>(state.parent_id);
        if (!body || !parent) continue;
        body->reparent(parent, false);
        body->set_transform(state.local_transform);
        parent->move_child(body, MIN(state.child_index, parent->get_child_count() - 1));
    }
    source_physics_states.clear();
    if (Node *quarantine = resolve<Node>(physics_quarantine_id)) quarantine->queue_free();
    physics_quarantine_id = 0;
    for (const MeshState &state : source_states) if (MeshInstance3D *mesh = resolve<MeshInstance3D>(state.id)) {
        replace_mesh_preserving_blends(mesh, state.original, true);
        for (int surface = 0; surface < int(state.original_surface_overrides.size()); ++surface) {
            mesh->set_surface_override_material(surface, state.original_surface_overrides[surface]);
        }
        mesh->set_custom_aabb(state.original_custom_aabb);
    }
    // Setting joint_offset resets the node from the simulator's cached pose, so
    // do that for every body before assigning the single coherent target pose.
    for (const ResetBody &state : reset_bodies) state.body->set_joint_offset(state.joint_offset);
    for (const ResetBody &state : reset_bodies) state.body->set_global_transform(state.world);
    for (const ResetBody &state : reset_bodies) {
        state.body->set_joint_type(state.joint_type);
        const Array names = state.constraints.keys();
        for (int i = 0; i < names.size(); ++i) state.body->set(names[i], state.constraints[names[i]]);
    }
    if (Skeleton3D *skeleton = get_skeleton()) {
        const Array hidden = hidden_bone_scales.keys();
        for (int i = 0; i < hidden.size(); ++i) {
            const int index = skeleton->find_bone(hidden[i]);
            // Keep the live animation pose. Assigning its current value only
            // invalidates the skin upload so removed render overrides disappear.
            if (index >= 0) skeleton->set_bone_pose_scale(index, skeleton->get_bone_pose_scale(index));
        }
        hidden_bone_scales.clear();
        hidden_bone_local_poses.clear();
        skeleton->force_update_all_bone_transforms();
        std::vector<Node *> nodes;
        gather_nodes(skeleton, nodes);
        for (Node *node : nodes) {
            PhysicalBone3D *physical = Object::cast_to<PhysicalBone3D>(node);
            if (!physical || !physical->has_meta("_godot_dismemberment_original_layer")) continue;
            physical->set_collision_layer(physical->get_meta("_godot_dismemberment_original_layer"));
            physical->set_collision_mask(physical->get_meta("_godot_dismemberment_original_mask"));
            physical->remove_meta("_godot_dismemberment_original_layer");
            physical->remove_meta("_godot_dismemberment_original_mask");
        }
    }
    // Let the owning simulator derive body modes and callbacks. A RIGID mode
    // captured during a later cut must never be restored onto an inactive bone.
    for (const SourceSimulatorState &state : source_simulator_states) if (Node *owner = resolve<Node>(state.id)) owner->call("physical_bones_stop_simulation");
    for (const SourceSimulatorState &state : source_simulator_states) if (!state.simulated_bones.is_empty()) if (Node *owner = resolve<Node>(state.id)) owner->call("physical_bones_start_simulation", state.simulated_bones);
    for (const ResetBody &state : reset_bodies) {
        state.body->set_global_transform(state.world);
        state.body->set_linear_velocity(resume_simulation ? state.linear : Vector3());
        state.body->set_angular_velocity(resume_simulation ? state.angular : Vector3());
    }
    // Publish the clean pose synchronously. R followed by another shot in this
    // same frame must not snapshot the previous ragdoll or a singular hide mask.
    if (source_skeleton) for (const MeshState &state : source_states) {
        MeshInstance3D *mesh = resolve<MeshInstance3D>(state.id);
        if (!mesh) continue;
        const Ref<SkinReference> reference = mesh->get_skin_reference();
        if (reference.is_null() || !reference->get_skeleton().is_valid()) continue;
        const Ref<Skin> skin = reference->get_skin();
        if (skin.is_null() || RenderingServer::get_singleton()->skeleton_get_bone_count(reference->get_skeleton()) < skin->get_bind_count()) continue;
        for (int bind = 0; bind < skin->get_bind_count(); ++bind) {
            const StringName name = skin->get_bind_name(bind);
            const int bone = name != StringName() ? source_skeleton->find_bone(name) : skin->get_bind_bone(bind);
            if (bone >= 0 && bone < int(reset_poses.size())) RenderingServer::get_singleton()->skeleton_bone_set_transform(reference->get_skeleton(), bind, reset_poses[bone] * skin->get_bind_pose(bind));
        }
    }
    source_simulator_states.clear();
    missing_limbs.clear();
    dismembered_bones.clear();
    destroyed_bones.clear();
    dismemberment_events.clear();
    ++replication_revision;
    emit_signal("limbs_reset");
    emit_signal("replication_state_changed", get_replication_state());
    if (network_enabled && is_inside_tree() && get_multiplayer()->has_multiplayer_peer() && is_multiplayer_authority()) rpc("_receive_state", get_replication_state());
}

Dictionary DismembermentComponent::get_replication_state() const {
    Dictionary state;
    state["version"] = 1;
    state["revision"] = replication_revision;
    state["dismembered_bones"] = dismembered_bones;
    state["destroyed_bones"] = destroyed_bones;
    state["events"] = dismemberment_events.duplicate(true);
    return state;
}

bool DismembermentComponent::apply_replication_state(const Dictionary &state) {
    if (!initialized && !initialize()) return false;
    if (int(state.get("version", 0)) != 1 || !state.has("revision") || state["revision"].get_type() != Variant::INT || !state.has("dismembered_bones") || !state.has("destroyed_bones")) return false;
    if (state["dismembered_bones"].get_type() != Variant::PACKED_STRING_ARRAY || state["destroyed_bones"].get_type() != Variant::PACKED_STRING_ARRAY) return false;
    const int revision = state["revision"];
    if (revision < 0 || revision < remote_revision) return false;
    const PackedStringArray cuts = state["dismembered_bones"];
    const PackedStringArray destroyed = state["destroyed_bones"];
    if (cuts.size() + destroyed.size() > get_skeleton()->get_bone_count()) return false;
    for (int i = 0; i < cuts.size(); ++i) if (!validate_bone(cuts[i])) return false;
    for (int i = 0; i < destroyed.size(); ++i) if (!validate_bone(destroyed[i])) return false;
    Array events;
    if (state.has("events")) {
        if (state["events"].get_type() != Variant::ARRAY) return false;
        events = state["events"];
        if (events.size() != cuts.size() + destroyed.size()) return false;
        PackedStringArray event_cuts;
        PackedStringArray event_destroyed;
        for (int i = 0; i < events.size(); ++i) {
            if (events[i].get_type() != Variant::DICTIONARY) return false;
            const Dictionary event = events[i];
            if (!event.has("bone") || !event.has("destroy") || event["destroy"].get_type() != Variant::BOOL) return false;
            const StringName event_bone = event["bone"];
            if (!validate_bone(event_bone)) return false;
            if (bool(event["destroy"])) event_destroyed.push_back(event_bone);
            else event_cuts.push_back(event_bone);
        }
        if (event_cuts != cuts || event_destroyed != destroyed) return false;
    }
    if (cuts == dismembered_bones && destroyed == destroyed_bones) { remote_revision = revision; replication_revision = revision; return true; }
    const bool enabled = network_enabled;
    network_enabled = false;
    reset_all_limbs();
    if (!events.is_empty()) {
        for (int i = 0; i < events.size(); ++i) {
            Dictionary event = events[i];
            if (bool(event["destroy"])) hide_internal(event["bone"]);
            else dismember_internal(event["bone"], Vector3(), true);
        }
    } else {
        for (int i = 0; i < cuts.size(); ++i) dismember_internal(cuts[i], Vector3(), true);
        for (int i = 0; i < destroyed.size(); ++i) hide_internal(destroyed[i]);
    }
    network_enabled = enabled;
    remote_revision = revision;
    replication_revision = revision;
    return true;
}

void DismembermentComponent::request_dismemberment(const StringName &bone_name, const Vector3 &impulse) {
    if (!network_enabled || !is_multiplayer_authority() || !is_inside_tree()) return;
    const int sender = get_multiplayer()->get_remote_sender_id();
    // Authority must explicitly delegate the node to its owning peer. Other
    // clients cannot issue cuts for an unrelated replicated character.
    if (sender != 0 && sender != owning_peer_id) return;
    dismember_limb(bone_name, impulse);
}

void DismembermentComponent::receive_dismemberment(const StringName &bone_name, const Vector3 &impulse, int revision) {
    if (!network_enabled || revision <= remote_revision || !impulse.is_finite() || impulse.length_squared() > 1.0e12 || !is_inside_tree()) return;
    const int sender = get_multiplayer()->get_remote_sender_id();
    if (sender != get_multiplayer_authority()) return;
    if (!initialized && !initialize()) return;
    dismember_internal(bone_name, impulse);
    remote_revision = revision;
    replication_revision = revision;
}

void DismembermentComponent::receive_state(const Dictionary &state) {
    if (!network_enabled || !is_inside_tree() || get_multiplayer()->get_remote_sender_id() != get_multiplayer_authority()) return;
    apply_replication_state(state);
}

void DismembermentComponent::synchronize_peer(int64_t peer_id) {
    if (network_enabled && is_inside_tree() && get_multiplayer()->has_multiplayer_peer() && is_multiplayer_authority() && peer_id > 0) rpc_id(peer_id, "_receive_state", get_replication_state());
}

void DismembermentComponent::on_peer_connected(int64_t peer_id) { synchronize_peer(peer_id); }

}
