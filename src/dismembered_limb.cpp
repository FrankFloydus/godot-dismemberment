#include "dismembered_limb.h"
#include <godot_cpp/classes/collision_shape3d.hpp>
#include <godot_cpp/classes/convex_polygon_shape3d.hpp>
#include <godot_cpp/classes/skin.hpp>
#include <godot_cpp/classes/skin_reference.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/physics_server3d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>
#include <vector>

namespace godot {

Transform3D evaluated_bone_pose(Skeleton3D *skeleton, MeshInstance3D *mesh, int bone) {
    if (!skeleton || bone < 0 || bone >= skeleton->get_bone_count()) return Transform3D();
    if (mesh) {
        const Ref<SkinReference> reference = mesh->get_skin_reference();
        if (reference.is_valid() && reference->get_skeleton().is_valid()) {
            const Ref<Skin> skin = reference->get_skin();
            RenderingServer *renderer = RenderingServer::get_singleton();
            if (skin.is_valid() && renderer->skeleton_get_bone_count(reference->get_skeleton()) >= skin->get_bind_count()) {
                Transform3D local_chain;
                for (int cursor = bone; cursor >= 0; cursor = skeleton->get_bone_parent(cursor)) {
                    for (int bind = 0; bind < skin->get_bind_count(); ++bind) {
                        const StringName name = skin->get_bind_name(bind);
                        const int mapped = name != StringName() ? skeleton->find_bone(name) : skin->get_bind_bone(bind);
                        if (mapped != cursor) continue;
                        const Transform3D pose = renderer->skeleton_bone_get_transform(reference->get_skeleton(), bind) * skin->get_bind_pose(bind).affine_inverse();
                        if (Math::abs(pose.basis.determinant()) >= 0.00000001) return pose * local_chain;
                    }
                    // Hidden skin palettes contain deliberately singular zero
                    // matrices. Recover an animation pose from the nearest
                    // retained evaluated ancestor; never invert the hide mask
                    // or fall back to an unrelated standing/rest world pose.
                    local_chain = skeleton->get_bone_pose(cursor) * local_chain;
                }
                return local_chain;
            }
        }
    }
    return skeleton->get_bone_global_pose(bone);
}

void DismemberedAnimInstance::_bind_methods() {
    ClassDB::bind_method(D_METHOD("set_limb", "value"), &DismemberedAnimInstance::set_limb);
    ClassDB::bind_method(D_METHOD("get_limb"), &DismemberedAnimInstance::get_limb);
    ClassDB::bind_method(D_METHOD("set_pelvis_bone_name", "value"), &DismemberedAnimInstance::set_pelvis_bone_name);
    ClassDB::bind_method(D_METHOD("get_pelvis_bone_name"), &DismemberedAnimInstance::get_pelvis_bone_name);
    ClassDB::bind_method(D_METHOD("capture_pose", "skeleton"), &DismemberedAnimInstance::capture_pose);
    ClassDB::bind_method(D_METHOD("apply_pose", "skeleton"), &DismemberedAnimInstance::apply_pose);
    ClassDB::bind_method(D_METHOD("get_bone_poses"), &DismemberedAnimInstance::get_bone_poses);
    ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "limb"), "set_limb", "get_limb");
    ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "pelvis_bone_name"), "set_pelvis_bone_name", "get_pelvis_bone_name");
}

void DismemberedAnimInstance::capture_pose(Skeleton3D *skeleton) {
    bone_poses.clear();
    if (!skeleton) return;
    for (int i = 0; i < skeleton->get_bone_count(); ++i) {
        Dictionary pose;
        pose["name"] = skeleton->get_bone_name(i);
        pose["transform"] = skeleton->get_bone_pose(i);
        bone_poses.push_back(pose);
    }
}

void DismemberedAnimInstance::apply_pose(Skeleton3D *skeleton) const {
    if (!skeleton) return;
    for (int i = 0; i < bone_poses.size(); ++i) {
        Dictionary pose = bone_poses[i];
        const int bone = skeleton->find_bone(pose.get("name", StringName()));
        if (bone >= 0) skeleton->set_bone_pose(bone, pose.get("transform", Transform3D()));
    }
}

void DismemberedLimb::_bind_methods() {
    ClassDB::bind_method(D_METHOD("set_bone_name", "value"), &DismemberedLimb::set_bone_name);
    ClassDB::bind_method(D_METHOD("get_bone_name"), &DismemberedLimb::get_bone_name);
    ClassDB::bind_method(D_METHOD("set_bone_transform", "value"), &DismemberedLimb::set_bone_transform);
    ClassDB::bind_method(D_METHOD("get_bone_transform"), &DismemberedLimb::get_bone_transform);
    ClassDB::bind_method(D_METHOD("set_anim_instance", "value"), &DismemberedLimb::set_anim_instance);
    ClassDB::bind_method(D_METHOD("get_anim_instance"), &DismemberedLimb::get_anim_instance);
    ClassDB::bind_method(D_METHOD("get_meshes"), &DismemberedLimb::get_meshes);
    ClassDB::bind_method(D_METHOD("build_collision"), &DismemberedLimb::build_collision);
    ClassDB::bind_method(D_METHOD("get_ragdoll_skeleton"), &DismemberedLimb::get_ragdoll_skeleton);
    ClassDB::bind_method(D_METHOD("is_articulated"), &DismemberedLimb::is_articulated);
    ClassDB::bind_method(D_METHOD("_apply_hidden_skin"), &DismemberedLimb::apply_hidden_skin);
    ClassDB::bind_method(D_METHOD("get_rigid_fallback_enabled"), &DismemberedLimb::get_rigid_fallback_enabled);
    ClassDB::bind_method(D_METHOD("set_lifetime", "value"), &DismemberedLimb::set_lifetime);
    ClassDB::bind_method(D_METHOD("get_lifetime"), &DismemberedLimb::get_lifetime);
    ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "bone_name"), "set_bone_name", "get_bone_name");
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "lifetime", PROPERTY_HINT_RANGE, "0,3600,0.1,or_greater"), "set_lifetime", "get_lifetime");
}

DismemberedLimb::DismemberedLimb() {
    add_to_group("Dismembered Limb");
    set_physics_process(false);
}

void DismemberedLimb::_ready() {
    RenderingServer *renderer = RenderingServer::get_singleton();
    const Callable callback(this, "_apply_hidden_skin");
    if (!renderer->is_connected("frame_pre_draw", callback)) renderer->connect("frame_pre_draw", callback);
}

void DismemberedLimb::apply_hidden_skin() {
    Skeleton3D *skeleton = get_ragdoll_skeleton();
    if (!skeleton || (!collapse_enabled && hidden_bone_roots.is_empty())) return;
    const TypedArray<MeshInstance3D> meshes = get_meshes();
    for (int m = 0; m < meshes.size(); ++m) {
        MeshInstance3D *mesh = Object::cast_to<MeshInstance3D>(meshes[m]);
        if (!mesh || mesh->get_skin().is_null()) continue;
        const Ref<SkinReference> reference = mesh->get_skin_reference();
        if (reference.is_null() || !reference->get_skeleton().is_valid()) continue;
        const Ref<Skin> skin = reference->get_skin();
        if (skin.is_null() || RenderingServer::get_singleton()->skeleton_get_bone_count(reference->get_skeleton()) < skin->get_bind_count()) continue;
        const int cut_root = skeleton->find_bone(collapse_root_bone);
        Transform3D root_delta;
        Transform3D current_root;
        if (collapse_enabled && cut_root >= 0 && cut_root < int(captured_global_poses.size())) {
            current_root = evaluated_bone_pose(skeleton, mesh, cut_root);
            // The root rigid body is authoritative even between render uploads.
            // Keep the collapsed complement attached to that moving body rather
            // than leaving tiny torso vertices anchored at the original cut.
            for (int p = 0; p < physical_bones.size(); ++p) {
                PhysicalBone3D *body = Object::cast_to<PhysicalBone3D>(physical_bones[p]);
                if (body && body->get_bone_id() == cut_root && body->is_simulating_physics()) {
                    current_root = skeleton->get_global_transform().affine_inverse() * body->get_global_transform() * body->get_body_offset().affine_inverse();
                    break;
                }
            }
            root_delta = current_root * captured_global_poses[cut_root].affine_inverse();
        }
        for (int bind = 0; bind < skin->get_bind_count(); ++bind) {
            const StringName name = skin->get_bind_name(bind);
            const int bone = name != StringName() ? skeleton->find_bone(name) : skin->get_bind_bone(bind);
            if (bone < 0 || bone >= skeleton->get_bone_count()) continue;
            bool selected = false;
            for (int cursor = bone; cursor >= 0; cursor = skeleton->get_bone_parent(cursor)) if (cursor == cut_root) { selected = true; break; }
            if (collapse_enabled && !selected && bone < int(captured_global_poses.size())) {
                Transform3D pose = root_delta * captured_global_poses[bone];
                pose.origin = current_root.origin + (pose.origin - current_root.origin) * complement_scale;
                pose.basis = pose.basis.scaled(Vector3(complement_scale, complement_scale, complement_scale));
                RenderingServer::get_singleton()->skeleton_bone_set_transform(reference->get_skeleton(), bind, pose * skin->get_bind_pose(bind));
            }
            int collapsed_root = -1;
            for (int r = 0; r < hidden_bone_roots.size(); ++r) {
                const int root = skeleton->find_bone(hidden_bone_roots[r]);
                bool selected = false;
                for (int cursor = bone; cursor >= 0; cursor = skeleton->get_bone_parent(cursor)) if (cursor == root) { selected = true; break; }
                if (!selected) continue;
                bool ancestor = collapsed_root < 0;
                for (int cursor = collapsed_root; cursor >= 0; cursor = skeleton->get_bone_parent(cursor)) if (cursor == root) { ancestor = true; break; }
                if (ancestor) collapsed_root = root;
            }
            if (collapsed_root >= 0) {
                Transform3D collapsed;
                collapsed.basis = Basis(Vector3(), Vector3(), Vector3());
                collapsed.origin = collapsed_root < int(captured_global_poses.size()) ? (root_delta * captured_global_poses[collapsed_root]).origin : skeleton->get_bone_global_pose(collapsed_root).origin;
                bool missing_inside_limb = false;
                for (int cursor = collapsed_root; cursor >= 0; cursor = skeleton->get_bone_parent(cursor)) if (cursor == cut_root) { missing_inside_limb = true; break; }
                if (collapse_enabled && !missing_inside_limb) {
                    // A previously removed sibling is part of the compressed
                    // complement. Its zero-scale anchor must be compressed too;
                    // otherwise mixed seam vertices stretch to its old location.
                    collapsed.origin = current_root.origin + (collapsed.origin - current_root.origin) * complement_scale;
                }
                RenderingServer::get_singleton()->skeleton_bone_set_transform(reference->get_skeleton(), bind, collapsed * skin->get_bind_pose(bind));
            }
        }
    }
}

static void gather_limb_meshes(const Node *node, TypedArray<MeshInstance3D> &result) {
    for (int i = 0; i < node->get_child_count(); ++i) {
        Node *child = node->get_child(i);
        if (MeshInstance3D *mesh = Object::cast_to<MeshInstance3D>(child)) result.push_back(mesh);
        gather_limb_meshes(child, result);
    }
}

TypedArray<MeshInstance3D> DismemberedLimb::get_meshes() const {
    TypedArray<MeshInstance3D> result;
    gather_limb_meshes(this, result);
    return result;
}

void DismemberedLimb::build_collision() {
    // Source EnGore uses the authored PhysicsAsset. A generated convex hull is
    // a separate, explicitly requested Godot convenience, never an automatic
    // substitute for missing authored ragdoll bodies.
    if (is_articulated() || !rigid_fallback_enabled) return;
    if (!collision_meshes.empty()) {
        for (const CollisionMesh &entry : collision_meshes) {
            if (entry.mesh.is_null()) continue;
            PackedVector3Array points;
            const Transform3D to_body = get_global_transform().affine_inverse() * entry.transform;
            for (int s = 0; s < entry.mesh->get_surface_count(); ++s) {
                const Array arrays = entry.mesh->surface_get_arrays(s);
                const PackedVector3Array vertices = arrays[Mesh::ARRAY_VERTEX];
                for (int v = 0; v < vertices.size(); ++v) points.push_back(to_body.xform(vertices[v]));
            }
            if (points.size() < 4) continue;
            Ref<ConvexPolygonShape3D> shape;
            shape.instantiate();
            shape->set_points(points);
            CollisionShape3D *collision = memnew(CollisionShape3D);
            collision->set_shape(shape);
            add_child(collision);
        }
        collision_meshes.clear();
        return;
    }
    TypedArray<MeshInstance3D> meshes = get_meshes();
    for (int i = 0; i < meshes.size(); ++i) {
        MeshInstance3D *mesh = Object::cast_to<MeshInstance3D>(meshes[i]);
        if (!mesh || mesh->get_mesh().is_null() || mesh->get_mesh()->get_surface_count() == 0) continue;
        // Construct convex points in rigid body coordinates; scaling a collision node
        // itself would produce invalid nonuniform physics transforms.
        PackedVector3Array points;
        const Transform3D to_body = get_global_transform().affine_inverse() * mesh->get_global_transform();
        const Ref<Mesh> resource = mesh->get_mesh();
        for (int s = 0; s < resource->get_surface_count(); ++s) {
            const Array arrays = resource->surface_get_arrays(s);
            const PackedVector3Array vertices = arrays[Mesh::ARRAY_VERTEX];
            for (int v = 0; v < vertices.size(); ++v) points.push_back(to_body.xform(vertices[v]));
        }
        if (points.size() < 4) continue;
        Ref<ConvexPolygonShape3D> shape;
        shape.instantiate();
        shape->set_points(points);
        CollisionShape3D *collision = memnew(CollisionShape3D);
        collision->set_shape(shape);
        add_child(collision);
    }
}

void DismemberedLimb::add_collision_mesh(const Ref<Mesh> &mesh, const Transform3D &transform) {
    collision_meshes.push_back({mesh, transform});
}

Skeleton3D *DismemberedLimb::prepare_pose_skeleton(Skeleton3D *source, MeshInstance3D *source_mesh) {
    if (Skeleton3D *existing = get_ragdoll_skeleton()) return existing;
    Skeleton3D *copy = memnew(Skeleton3D);
    copy->set_name("DetachedSkeleton");
    captured_global_poses.clear();
    for (int i = 0; i < source->get_bone_count(); ++i) {
        Transform3D pose = evaluated_bone_pose(source, source_mesh, i);
        if (Math::abs(pose.basis.determinant()) < 0.00000001) pose = source->get_bone_global_pose(i);
        if (Math::abs(pose.basis.determinant()) < 0.00000001) pose.basis = source->get_bone_global_rest(i).basis.orthonormalized().scaled(Vector3(0.0001, 0.0001, 0.0001));
        captured_global_poses.push_back(pose);
    }
    for (int i = 0; i < source->get_bone_count(); ++i) {
        copy->add_bone(source->get_bone_name(i));
        copy->set_bone_parent(i, source->get_bone_parent(i));
        copy->set_bone_rest(i, source->get_bone_rest(i));
        const int parent = source->get_bone_parent(i);
        const Transform3D local = parent >= 0 ? captured_global_poses[parent].affine_inverse() * captured_global_poses[i] : captured_global_poses[i];
        copy->set_bone_pose(i, local);
    }
    add_child(copy);
    copy->set_global_transform(source->get_global_transform());
    copy->force_update_all_bone_transforms();
    ragdoll_skeleton_id = uint64_t(copy->get_instance_id());
    return copy;
}

void DismemberedLimb::collapse_complement(const StringName &limb_root, double scale) {
    collapse_root_bone = limb_root;
    complement_scale = scale;
    collapse_enabled = true;
}

static void collect_physical_bones(Node *node, std::vector<PhysicalBone3D *> &out) {
    for (int i = 0; i < node->get_child_count(); ++i) {
        Node *child = node->get_child(i);
        if (PhysicalBone3D *physical = Object::cast_to<PhysicalBone3D>(child)) out.push_back(physical);
        collect_physical_bones(child, out);
    }
}

bool DismemberedLimb::prepare_articulated_physics(Skeleton3D *source, const StringName &root_bone, const PackedStringArray &missing_bones, uint32_t layer, uint32_t mask) {
    if (!source) return false;
    const int root = source->find_bone(root_bone);
    if (root < 0) return false;
    std::vector<PhysicalBone3D *> candidates;
    std::vector<PhysicalBone3D *> selected;
    collect_physical_bones(source, candidates);
    for (PhysicalBone3D *body : candidates) {
        const int index = body->get_bone_id();
        if (index < 0 || index >= source->get_bone_count() || missing_bones.has(source->get_bone_name(index))) continue;
        for (int cursor = index; cursor >= 0; cursor = source->get_bone_parent(cursor)) {
            if (cursor == root) { selected.push_back(body); break; }
        }
    }
    if (selected.empty()) return false;
    Skeleton3D *copy = prepare_pose_skeleton(source);
    struct BodyClone {
        PhysicalBone3D *source;
        PhysicalBone3D *clone;
        PhysicalBone3D::JointType joint_type;
        Dictionary joint_properties;
    };
    std::vector<BodyClone> cloned_bodies;
    for (PhysicalBone3D *body : selected) {
        Dictionary joint_properties;
        const TypedArray<Dictionary> properties = body->get_property_list();
        for (int property_index = 0; property_index < properties.size(); ++property_index) {
            const Dictionary property = properties[property_index];
            const String name = property.get("name", String());
            if (name.begins_with("joint_constraints/")) joint_properties[name] = body->get(name);
        }
        PhysicalBone3D *clone = Object::cast_to<PhysicalBone3D>(body->duplicate(0));
        if (!clone) continue;
        const int index = body->get_bone_id();
        const PhysicalBone3D::JointType authored_joint_type = body->get_joint_type();
        // Add every body before rebuilding any joint. Otherwise insertion
        // order can leave a joint attached to an absent or rest-pose parent.
        clone->set_joint_type(PhysicalBone3D::JOINT_TYPE_NONE);
        clone->set("bone_name", source->get_bone_name(index));
        clone->set_collision_layer(layer);
        clone->set_collision_mask(mask);
        copy->add_child(clone);
        clone->set_global_transform(body->get_global_transform());
        PhysicsServer3D *server = PhysicsServer3D::get_singleton();
        // PhysicalBone's node getters cache the last simulated velocities.
        // Stopping/resetting makes the solver body static and zeroes its live
        // velocity, while those node fields can retain the previous ragdoll's
        // motion. Read authoritative solver state when inheriting motion.
        inherited_motion.push_back({uint64_t(clone->get_instance_id()),
                Vector3(server->body_get_state(body->get_rid(), PhysicsServer3D::BODY_STATE_LINEAR_VELOCITY)),
                Vector3(server->body_get_state(body->get_rid(), PhysicsServer3D::BODY_STATE_ANGULAR_VELOCITY))});
        // Inactive Godot Physics bodies report zero inertia even if a custom
        // tensor was assigned. Zero therefore means "derive from shapes", not
        // an explicit inertia tensor. Importers can retain authored values in
        // metadata, which also supports custom COM exactly at the origin.
        // Older projects may already store either authored value under the
        // previous addon name. Prefer the current key when both are present.
        const StringName center_key = body->has_meta("godot_dismemberment_center_of_mass") ?
                "godot_dismemberment_center_of_mass" : "godot_prefabs_center_of_mass";
        const StringName inertia_key = body->has_meta("godot_dismemberment_inertia") ?
                "godot_dismemberment_inertia" : "godot_prefabs_inertia";
        const bool has_authored_center = body->has_meta(center_key);
        const Vector3 center_of_mass = has_authored_center ?
                Vector3(body->get_meta(center_key)) :
                Vector3(server->body_get_param(body->get_rid(), PhysicsServer3D::BODY_PARAM_CENTER_OF_MASS));
        const Vector3 inertia = body->has_meta(inertia_key) ?
                Vector3(body->get_meta(inertia_key)) :
                Vector3(server->body_get_param(body->get_rid(), PhysicsServer3D::BODY_PARAM_INERTIA));
        if (center_of_mass.is_finite() && (has_authored_center || !center_of_mass.is_zero_approx()))
            server->body_set_param(clone->get_rid(), PhysicsServer3D::BODY_PARAM_CENTER_OF_MASS, center_of_mass);
        if (inertia.is_finite() && inertia.x > 0.0 && inertia.y > 0.0 && inertia.z > 0.0)
            server->body_set_param(clone->get_rid(), PhysicsServer3D::BODY_PARAM_INERTIA, inertia);
        physical_bones.push_back(clone);
        cloned_bodies.push_back({body, clone, authored_joint_type, joint_properties});
    }
    for (BodyClone &entry : cloned_bodies) {
        bool parent_is_selected = false;
        for (int ancestor = source->get_bone_parent(entry.source->get_bone_id()); ancestor >= 0; ancestor = source->get_bone_parent(ancestor)) {
            for (const BodyClone &other : cloned_bodies) {
                if (other.source->get_bone_id() == ancestor) { parent_is_selected = true; break; }
            }
            if (parent_is_selected) break;
        }
        // PhysicsAssets often skip intermediate bones (spine -> neck -> head).
        // Keep the nearest physical ancestor joint, rather than requiring an
        // immediate skeleton parent body. The severed root itself has no joint.
        if (parent_is_selected) {
            entry.clone->set_joint_offset(entry.source->get_joint_offset());
            entry.clone->set_global_transform(entry.source->get_global_transform());
            // Godot computes the parent frame from these current body poses.
            // This is the runtime pose-anchor equivalent of the source patch;
            // it avoids reusing a rest-pose parent translation after a cut.
            entry.clone->set_joint_type(entry.joint_type);
            const Array names = entry.joint_properties.keys();
            for (int property_index = 0; property_index < names.size(); ++property_index) {
                const StringName name = names[property_index];
                entry.clone->set(name, entry.joint_properties[name]);
            }
        }
        const TypedArray<PhysicsBody3D> excluded = entry.source->get_collision_exceptions();
        for (const BodyClone &other : cloned_bodies) {
            if (excluded.has(other.source)) entry.clone->add_collision_exception_with(other.clone);
        }
    }
    if (physical_bones.is_empty()) {
        copy->queue_free();
        ragdoll_skeleton_id = 0;
        return false;
    }
    set_collision_layer(0);
    set_collision_mask(0);
    return true;
}

Skeleton3D *DismemberedLimb::get_ragdoll_skeleton() const {
    return ragdoll_skeleton_id ? Object::cast_to<Skeleton3D>(ObjectDB::get_instance(ragdoll_skeleton_id)) : nullptr;
}

void DismemberedLimb::begin_simulation(const Vector3 &impulse) {
    Skeleton3D *skeleton = get_ragdoll_skeleton();
    if (!skeleton || !is_articulated()) {
        if (!rigid_fallback_enabled) return;
        set_freeze_enabled(false);
        // Unreal's source uses AddImpulse(..., velocity_change=true). Convert
        // the requested velocity change to Godot's mass-dependent momentum.
        if (!impulse.is_zero_approx()) apply_central_impulse(impulse * get_mass());
        return;
    }
    TypedArray<StringName> names;
    PhysicalBone3D *impulse_body = nullptr;
    for (int i = 0; i < physical_bones.size(); ++i) {
        PhysicalBone3D *body = Object::cast_to<PhysicalBone3D>(physical_bones[i]);
        if (!body || body->get_bone_id() < 0) continue;
        names.push_back(skeleton->get_bone_name(body->get_bone_id()));
        if (!impulse_body || skeleton->get_bone_name(body->get_bone_id()) == String(bone_name)) impulse_body = body;
    }
    skeleton->physical_bones_start_simulation(names);
    // Apply inherited motion after the static-to-rigid transition. Jolt clears
    // velocity on that transition; assigning it while bodies are still static
    // would silently discard the source momentum on the first simulated frame.
    for (const InheritedMotion &motion : inherited_motion) {
        PhysicalBone3D *body = Object::cast_to<PhysicalBone3D>(ObjectDB::get_instance(motion.body_id));
        if (!body || !body->is_simulating_physics()) continue;
        body->set_linear_velocity(motion.linear);
        body->set_angular_velocity(motion.angular);
    }
    inherited_motion.clear();
    if (impulse_body && !impulse.is_zero_approx()) impulse_body->apply_central_impulse(impulse * impulse_body->get_mass());
}

void DismemberedLimb::_physics_process(double delta) {
    if (lifetime <= 0.0) return;
    age += delta;
    if (age >= lifetime) queue_free();
}

}
