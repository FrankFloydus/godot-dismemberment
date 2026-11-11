#include "limb_map.h"

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/classes/skin.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/typed_array.hpp>

#include <algorithm>

namespace godot {

LimbMap::LimbMap() = default;

void LimbMap::_bind_methods() {
	ClassDB::bind_method(D_METHOD("initialize", "skeleton", "mesh"), &LimbMap::initialize, DEFVAL(nullptr));
	ClassDB::bind_method(D_METHOD("get_skeleton"), &LimbMap::get_skeleton);
	ClassDB::bind_method(D_METHOD("get_mesh_instance"), &LimbMap::get_mesh_instance);
	ClassDB::bind_method(D_METHOD("set_exclude", "keywords"), &LimbMap::set_exclude);
	ClassDB::bind_method(D_METHOD("get_exclude"), &LimbMap::get_exclude);
	ClassDB::bind_method(D_METHOD("has_excluded_keyword", "name"), &LimbMap::has_excluded_keyword);
	ClassDB::bind_method(D_METHOD("is_bone_excluded", "bone"), &LimbMap::is_bone_excluded);
	ClassDB::bind_method(D_METHOD("get_vertex_num"), &LimbMap::get_vertex_num);
	ClassDB::bind_method(D_METHOD("get_bone_name", "index"), &LimbMap::get_bone_name);
	ClassDB::bind_method(D_METHOD("get_bone_index", "bone"), &LimbMap::get_bone_index);
	ClassDB::bind_method(D_METHOD("get_all_child_bones", "index"), &LimbMap::get_all_child_bones);
	ClassDB::bind_method(D_METHOD("get_child_bones", "bone"), &LimbMap::get_child_bones);
	ClassDB::bind_method(D_METHOD("get_direct_child_bones", "index"), &LimbMap::get_direct_child_bones);
	ClassDB::bind_method(D_METHOD("get_direct_child_bone", "bone"), &LimbMap::get_direct_child_bone);
	ClassDB::bind_method(D_METHOD("get_bone_path_to_root", "bone"), &LimbMap::get_bone_path_to_root);
	ClassDB::bind_method(D_METHOD("get_bone_reference_transform", "bone"), &LimbMap::get_bone_reference_transform);
	ClassDB::bind_method(D_METHOD("get_limb_indices", "bone"), &LimbMap::get_limb_indices);
	ClassDB::bind_method(D_METHOD("get_all_bones_of_limb", "bone"), &LimbMap::get_all_bones_of_limb);
	ClassDB::bind_method(D_METHOD("get_all_immediate_bones", "bone"), &LimbMap::get_all_immediate_bones);
	ClassDB::bind_method(D_METHOD("get_limb", "bone"), &LimbMap::get_limb);
	ClassDB::bind_method(D_METHOD("remove_excluded_bones", "bones"), &LimbMap::remove_excluded_bones);
	ClassDB::bind_method(D_METHOD("convert_bones_to_names", "bones"), &LimbMap::convert_bones_to_names);
	ClassDB::bind_method(D_METHOD("get_mapped_bone_index", "skin_bind_index"), &LimbMap::get_mapped_bone_index);
	ClassDB::bind_method(D_METHOD("get_mapped_bone_indices", "skin_bind_indices"), &LimbMap::get_mapped_bone_indices);
	ClassDB::bind_method(D_METHOD("get_mapped_raw_bone_index", "skeleton_bone_index"), &LimbMap::get_mapped_raw_bone_index);
	ClassDB::bind_method(D_METHOD("get_raw_bone_index", "skeleton_bone_index"), &LimbMap::get_raw_bone_index);
	ClassDB::bind_method(D_METHOD("get_vertex_influences", "vertex_index"), &LimbMap::get_vertex_influences);
	ClassDB::bind_method(D_METHOD("get_bone_with_most_influence", "vertex_index"), &LimbMap::get_bone_with_most_influence);
	ClassDB::bind_method(D_METHOD("has_bone_weight", "vertex_index", "bone_index", "threshold"), &LimbMap::has_bone_weight, DEFVAL(0.5));
	ClassDB::bind_method(D_METHOD("get_weight", "vertex_index", "bone_index"), &LimbMap::get_weight);
	ClassDB::bind_method(D_METHOD("get_all_bones_with_influence", "vertex_index", "threshold"), &LimbMap::get_all_bones_with_influence, DEFVAL(0.5));
	ClassDB::bind_method(D_METHOD("get_weights_of_bone", "bone"), &LimbMap::get_weights_of_bone);
	ClassDB::bind_method(D_METHOD("get_mask_of_bone", "bone", "threshold"), &LimbMap::get_mask_of_bone, DEFVAL(0.25));
	ClassDB::bind_method(D_METHOD("get_weights_of_limb", "bone"), &LimbMap::get_weights_of_limb);
	ClassDB::bind_method(D_METHOD("get_mask_of_limb", "bone", "threshold"), &LimbMap::get_mask_of_limb, DEFVAL(0.25));
	ClassDB::bind_method(D_METHOD("get_mask_of_immediate_limb", "bone", "threshold", "include_bone"), &LimbMap::get_mask_of_immediate_limb, DEFVAL(0.25), DEFVAL(true));
	ClassDB::bind_method(D_METHOD("get_all_limb_vertices", "bone"), &LimbMap::get_all_limb_vertices);
	ClassDB::bind_method(D_METHOD("set_limb_weights", "mesh", "bone", "threshold"), &LimbMap::set_limb_weights, DEFVAL(0.25));
	ClassDB::bind_method(D_METHOD("get_vertex_weight_color_for_bone", "bone"), &LimbMap::get_vertex_weight_color_for_bone);
	ClassDB::bind_method(D_METHOD("get_vertex_weight_color_for_limb", "bone", "threshold"), &LimbMap::get_vertex_weight_color_for_limb, DEFVAL(0.5));
	ClassDB::bind_static_method("LimbMap", D_METHOD("has_any_matching_names", "one", "two"), &LimbMap::has_any_matching_names);
	ClassDB::bind_static_method("LimbMap", D_METHOD("has_any_matching_ints", "one", "two"), &LimbMap::has_any_matching_ints);
	ClassDB::bind_static_method("LimbMap", D_METHOD("get_limb_map", "map"), &LimbMap::get_limb_map);
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_STRING_ARRAY, "exclude"), "set_exclude", "get_exclude");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "vertex_num", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR), "", "get_vertex_num");
}

bool LimbMap::initialize(Skeleton3D *skeleton, MeshInstance3D *mesh) {
	skeleton_id = skeleton ? skeleton->get_instance_id() : 0;
	mesh_instance_id = mesh ? mesh->get_instance_id() : 0;
	return skeleton != nullptr;
}

Ref<LimbMap> LimbMap::get_limb_map(const Ref<LimbMap> &map) { return map; }

Skeleton3D *LimbMap::get_skeleton() const {
	return skeleton_id ? Object::cast_to<Skeleton3D>(ObjectDB::get_instance(skeleton_id)) : nullptr;
}

MeshInstance3D *LimbMap::get_mesh_instance() const {
	return mesh_instance_id ? Object::cast_to<MeshInstance3D>(ObjectDB::get_instance(mesh_instance_id)) : nullptr;
}

void LimbMap::set_exclude(const PackedStringArray &value) { exclude = value; emit_changed(); }
PackedStringArray LimbMap::get_exclude() const { return exclude; }

bool LimbMap::has_excluded_keyword(const String &name) const {
	for (int64_t i = 0; i < exclude.size(); ++i) {
		if (!exclude[i].is_empty() && name.containsn(exclude[i])) return true;
	}
	return false;
}

bool LimbMap::is_bone_excluded(const StringName &bone) const { return has_excluded_keyword(String(bone)); }

int LimbMap::get_vertex_num() const {
	MeshInstance3D *instance = get_mesh_instance();
	if (!instance || instance->get_mesh().is_null()) return 0;
	Ref<Mesh> mesh = instance->get_mesh();
	int total = 0;
	for (int surface = 0; surface < mesh->get_surface_count(); ++surface) {
		Array arrays = mesh->surface_get_arrays(surface);
		if (arrays.size() == Mesh::ARRAY_MAX) {
			PackedVector3Array vertices = arrays[Mesh::ARRAY_VERTEX];
			total += static_cast<int>(vertices.size());
		}
	}
	return total;
}

StringName LimbMap::get_bone_name(int index) const {
	Skeleton3D *skeleton = get_skeleton();
	return skeleton && index >= 0 && index < skeleton->get_bone_count() ? StringName(skeleton->get_bone_name(index)) : StringName();
}

int LimbMap::get_bone_index(const StringName &bone) const {
	Skeleton3D *skeleton = get_skeleton();
	return skeleton ? skeleton->find_bone(String(bone)) : -1;
}

PackedInt32Array LimbMap::get_direct_child_bones(int index) const {
	Skeleton3D *skeleton = get_skeleton();
	return skeleton && index >= 0 && index < skeleton->get_bone_count() ? skeleton->get_bone_children(index) : PackedInt32Array();
}

void LimbMap::append_descendants(int bone, PackedInt32Array &out, bool apply_exclusions) const {
	PackedInt32Array children = get_direct_child_bones(bone);
	for (int64_t i = 0; i < children.size(); ++i) {
		if (!out.has(children[i])) out.append(children[i]);
	}
	for (int64_t i = 0; i < children.size(); ++i) append_descendants(children[i], out, false);
	if (apply_exclusions) out = remove_excluded_bones(out);
}

PackedInt32Array LimbMap::get_all_child_bones(int index) const {
	PackedInt32Array result;
	if (get_bone_name(index) != StringName()) append_descendants(index, result, false);
	return result;
}

PackedStringArray LimbMap::get_child_bones(const StringName &bone) const {
	return convert_bones_to_names(remove_excluded_bones(get_all_child_bones(get_bone_index(bone))));
}

StringName LimbMap::get_direct_child_bone(const StringName &bone) const {
	PackedStringArray children = get_child_bones(bone);
	return children.is_empty() ? StringName() : StringName(children[0]);
}

PackedStringArray LimbMap::get_bone_path_to_root(const StringName &bone) const {
	PackedStringArray result;
	result.append(String(bone));
	Skeleton3D *skeleton = get_skeleton();
	int index = get_bone_index(bone);
	int remaining = skeleton ? skeleton->get_bone_count() : 0;
	while (skeleton && index >= 0 && remaining-- > 0) {
		index = skeleton->get_bone_parent(index);
		if (index >= 0) result.append(skeleton->get_bone_name(index));
	}
	return result;
}

Transform3D LimbMap::get_bone_reference_transform(const StringName &bone) const {
	Skeleton3D *skeleton = get_skeleton();
	int index = get_bone_index(bone);
	return skeleton && index >= 0 ? skeleton->get_bone_global_rest(index) : Transform3D();
}

PackedInt32Array LimbMap::get_limb_indices(const StringName &bone) const {
	PackedInt32Array result;
	int index = get_bone_index(bone);
	if (index < 0) return result;
	result.append(index);
	PackedInt32Array children = remove_excluded_bones(get_all_child_bones(index));
	result.append_array(children);
	return result;
}

PackedStringArray LimbMap::get_all_bones_of_limb(const StringName &bone) const { return convert_bones_to_names(get_limb_indices(bone)); }

PackedInt32Array LimbMap::get_all_immediate_bones(const StringName &bone) const {
	PackedInt32Array result;
	Skeleton3D *skeleton = get_skeleton();
	if (!skeleton || get_bone_index(bone) < 0) return result;
	PackedInt32Array limb = get_limb_indices(bone);
	for (int i = 0; i < skeleton->get_bone_count(); ++i) if (!limb.has(i)) result.append(i);
	return result;
}

Dictionary LimbMap::get_limb(const StringName &bone) const {
	Dictionary result;
	result["bone_name"] = bone;
	result["bone_index"] = get_bone_index(bone);
	result["limb"] = get_all_bones_of_limb(bone);
	result["child_bones"] = get_limb_indices(bone);
	result["reference_bone_transform"] = get_bone_reference_transform(bone);
	return result;
}

PackedInt32Array LimbMap::remove_excluded_bones(const PackedInt32Array &bones) const {
	PackedInt32Array result;
	for (int64_t i = 0; i < bones.size(); ++i) if (!is_bone_excluded(get_bone_name(bones[i]))) result.append(bones[i]);
	return result;
}

PackedStringArray LimbMap::convert_bones_to_names(const PackedInt32Array &bones) const {
	PackedStringArray result;
	for (int64_t i = 0; i < bones.size(); ++i) result.append(String(get_bone_name(bones[i])));
	return result;
}

int LimbMap::get_mapped_bone_index(int skin_bind_index) const {
	MeshInstance3D *instance = get_mesh_instance();
	Skeleton3D *skeleton = get_skeleton();
	if (!skeleton || skin_bind_index < 0) return -1;
	Ref<Skin> skin = instance ? instance->get_skin() : Ref<Skin>();
	if (skin.is_null()) return skin_bind_index < skeleton->get_bone_count() ? skin_bind_index : -1;
	if (skin_bind_index >= skin->get_bind_count()) return -1;
	StringName name = skin->get_bind_name(skin_bind_index);
	if (name != StringName()) return skeleton->find_bone(String(name));
	int bone = skin->get_bind_bone(skin_bind_index);
	return bone >= 0 && bone < skeleton->get_bone_count() ? bone : -1;
}

PackedInt32Array LimbMap::get_mapped_bone_indices(const PackedInt32Array &indices) const {
	PackedInt32Array result;
	for (int64_t i = 0; i < indices.size(); ++i) result.append(get_mapped_bone_index(indices[i]));
	return result;
}

int LimbMap::get_mapped_raw_bone_index(int bone) const {
	MeshInstance3D *instance = get_mesh_instance();
	Ref<Skin> skin = instance ? instance->get_skin() : Ref<Skin>();
	if (skin.is_null()) return bone >= 0 && bone < (get_skeleton() ? get_skeleton()->get_bone_count() : 0) ? bone : -1;
	for (int i = 0; i < skin->get_bind_count(); ++i) if (get_mapped_bone_index(i) == bone) return i;
	return -1;
}

int LimbMap::get_raw_bone_index(int bone) const { return get_mapped_raw_bone_index(bone); }

Dictionary LimbMap::get_vertex_influences(int vertex_index) const {
	Dictionary result;
	PackedInt32Array out_bones;
	PackedFloat32Array out_weights;
	MeshInstance3D *instance = get_mesh_instance();
	if (instance && instance->get_mesh().is_valid() && vertex_index >= 0) {
		Ref<Mesh> mesh = instance->get_mesh();
		for (int surface = 0; surface < mesh->get_surface_count(); ++surface) {
			Array arrays = mesh->surface_get_arrays(surface);
			if (arrays.size() != Mesh::ARRAY_MAX) continue;
			PackedVector3Array vertices = arrays[Mesh::ARRAY_VERTEX];
			if (vertex_index >= vertices.size()) { vertex_index -= static_cast<int>(vertices.size()); continue; }
			PackedInt32Array bones = arrays[Mesh::ARRAY_BONES];
			PackedFloat32Array weights = arrays[Mesh::ARRAY_WEIGHTS];
			int stride = vertices.is_empty() ? 0 : static_cast<int>(bones.size() / vertices.size());
			if ((stride == 4 || stride == 8) && weights.size() == bones.size()) {
				for (int j = 0; j < stride; ++j) {
					out_bones.append(get_mapped_bone_index(bones[vertex_index * stride + j]));
					out_weights.append(weights[vertex_index * stride + j]);
				}
			}
			break;
		}
	}
	result["bones"] = out_bones;
	result["weights"] = out_weights;
	return result;
}

int LimbMap::get_bone_with_most_influence(int vertex_index) const {
	Dictionary data = get_vertex_influences(vertex_index);
	PackedInt32Array bones = data["bones"];
	PackedFloat32Array weights = data["weights"];
	int result = -1;
	float maximum = 0;
	for (int64_t i = 0; i < bones.size(); ++i) if (weights[i] > maximum) { maximum = weights[i]; result = bones[i]; }
	return result;
}

double LimbMap::get_weight(int vertex_index, int bone_index) const {
	Dictionary data = get_vertex_influences(vertex_index);
	PackedInt32Array bones = data["bones"];
	PackedFloat32Array weights = data["weights"];
	double result = 0;
	for (int64_t i = 0; i < bones.size(); ++i) if (bones[i] == bone_index && bone_index >= 0) result = std::max(result, static_cast<double>(weights[i]));
	return result;
}

bool LimbMap::has_bone_weight(int vertex_index, int bone_index, double threshold) const { return bone_index >= 0 && get_weight(vertex_index, bone_index) > threshold; }

PackedInt32Array LimbMap::get_all_bones_with_influence(int vertex_index, double threshold) const {
	Dictionary data = get_vertex_influences(vertex_index);
	PackedInt32Array bones = data["bones"];
	PackedFloat32Array weights = data["weights"];
	PackedInt32Array result;
	for (int64_t i = 0; i < bones.size(); ++i) if (bones[i] >= 0 && weights[i] >= threshold && !result.has(bones[i])) result.append(bones[i]);
	return result;
}

PackedFloat32Array LimbMap::weights_for_indices(const PackedInt32Array &indices) const {
	PackedFloat32Array result;
	MeshInstance3D *instance = get_mesh_instance();
	if (!instance || instance->get_mesh().is_null()) return result;
	Ref<Mesh> mesh = instance->get_mesh();
	for (int surface = 0; surface < mesh->get_surface_count(); ++surface) {
		Array arrays = mesh->surface_get_arrays(surface);
		if (arrays.size() != Mesh::ARRAY_MAX) continue;
		PackedVector3Array vertices = arrays[Mesh::ARRAY_VERTEX];
		PackedInt32Array bones = arrays[Mesh::ARRAY_BONES];
		PackedFloat32Array weights = arrays[Mesh::ARRAY_WEIGHTS];
		int stride = vertices.is_empty() ? 0 : static_cast<int>(bones.size() / vertices.size());
		bool valid = (stride == 4 || stride == 8) && bones.size() == weights.size();
		for (int64_t vertex = 0; vertex < vertices.size(); ++vertex) {
			float maximum = 0;
			if (valid) for (int j = 0; j < stride; ++j) {
				int64_t offset = vertex * stride + j;
				if (indices.has(get_mapped_bone_index(bones[offset]))) maximum = std::max(maximum, weights[offset]);
			}
			result.append(maximum);
		}
	}
	return result;
}

PackedFloat32Array LimbMap::mask_for_indices(const PackedInt32Array &indices, double threshold) const {
	PackedFloat32Array result = weights_for_indices(indices);
	// An empty/invalid limb can never select vertices, even at a zero threshold.
	for (int64_t i = 0; i < result.size(); ++i) result.set(i, !indices.is_empty() && result[i] > 0 && result[i] >= threshold ? 1.0f : 0.0f);
	return result;
}

PackedFloat32Array LimbMap::get_weights_of_bone(const StringName &bone) const {
	PackedInt32Array indices;
	int index = get_bone_index(bone);
	if (index >= 0) indices.append(index);
	return weights_for_indices(indices);
}

PackedFloat32Array LimbMap::get_mask_of_bone(const StringName &bone, double threshold) const {
	PackedInt32Array indices;
	int index = get_bone_index(bone);
	if (index >= 0) indices.append(index);
	return mask_for_indices(indices, threshold);
}

PackedFloat32Array LimbMap::get_weights_of_limb(const StringName &bone) const { return weights_for_indices(get_limb_indices(bone)); }
PackedFloat32Array LimbMap::get_mask_of_limb(const StringName &bone, double threshold) const { return mask_for_indices(get_limb_indices(bone), threshold); }

PackedFloat32Array LimbMap::get_mask_of_immediate_limb(const StringName &bone, double threshold, bool include_bone) const {
	PackedInt32Array indices = get_all_immediate_bones(bone);
	int index = get_bone_index(bone);
	if (include_bone && index >= 0) indices.append(index);
	return mask_for_indices(indices, threshold);
}

PackedInt32Array LimbMap::get_all_limb_vertices(const StringName &bone) const {
	PackedFloat32Array weights = get_weights_of_limb(bone);
	PackedInt32Array result;
	for (int64_t i = 0; i < weights.size(); ++i) if (weights[i] > 0) result.append(static_cast<int32_t>(i));
	return result;
}

bool LimbMap::set_limb_weights(MeshInstance3D *instance, const StringName &bone, double threshold) {
	if (!instance || instance->get_mesh().is_null() || get_bone_index(bone) < 0) return false;
	uint64_t previous_instance = mesh_instance_id;
	mesh_instance_id = instance->get_instance_id();
	int bind_index = get_mapped_raw_bone_index(get_bone_index(bone));
	if (bind_index < 0) { mesh_instance_id = previous_instance; return false; }
	PackedFloat32Array mask = get_mask_of_immediate_limb(bone, threshold, true);
	PackedFloat32Array blend_values;
	for (int i = 0; i < instance->get_blend_shape_count(); ++i) blend_values.append(instance->get_blend_shape_value(i));
	Ref<Mesh> original = instance->get_mesh();
	Ref<ArrayMesh> array_original = original;
	Ref<ArrayMesh> cloned;
	cloned.instantiate();
	if (array_original.is_valid()) {
		cloned->set_blend_shape_mode(array_original->get_blend_shape_mode());
		for (int i = 0; i < array_original->get_blend_shape_count(); ++i) cloned->add_blend_shape(array_original->get_blend_shape_name(i));
	}
	int64_t vertex_offset = 0;
	for (int surface = 0; surface < original->get_surface_count(); ++surface) {
		Array arrays = original->surface_get_arrays(surface).duplicate(true);
		if (arrays.size() != Mesh::ARRAY_MAX) continue;
		PackedVector3Array vertices = arrays[Mesh::ARRAY_VERTEX];
		PackedInt32Array bones = arrays[Mesh::ARRAY_BONES];
		PackedFloat32Array weights = arrays[Mesh::ARRAY_WEIGHTS];
		int stride = vertices.is_empty() ? 0 : static_cast<int>(bones.size() / vertices.size());
		if ((stride == 4 || stride == 8) && weights.size() == bones.size()) {
			for (int64_t vertex = 0; vertex < vertices.size(); ++vertex) if (mask[vertex_offset + vertex] > 0) {
				for (int influence = 0; influence < stride; ++influence) {
					bones.set(vertex * stride + influence, bind_index);
					weights.set(vertex * stride + influence, influence == 0 ? 1.0f : 0.0f);
				}
			}
			arrays[Mesh::ARRAY_BONES] = bones;
			arrays[Mesh::ARRAY_WEIGHTS] = weights;
		}
		vertex_offset += vertices.size();
		uint64_t flags = array_original.is_valid() ? static_cast<uint64_t>(array_original->surface_get_format(surface)) : 0;
		// Let Godot infer populated arrays; retain custom channel formats and flags.
		flags &= ~((uint64_t(1) << Mesh::ARRAY_MAX) - 1);
		Mesh::PrimitiveType primitive = array_original.is_valid() ? array_original->surface_get_primitive_type(surface) : Mesh::PRIMITIVE_TRIANGLES;
		TypedArray<Array> blend_shapes = original->surface_get_blend_shape_arrays(surface);
		cloned->add_surface_from_arrays(primitive, arrays, blend_shapes, Dictionary(), flags);
		int new_surface = cloned->get_surface_count() - 1;
		if (new_surface >= 0) {
			cloned->surface_set_material(new_surface, instance->get_active_material(surface));
			if (array_original.is_valid()) cloned->surface_set_name(new_surface, array_original->surface_get_name(surface));
		}
	}
	if (cloned->get_surface_count() != original->get_surface_count()) { mesh_instance_id = previous_instance; return false; }
	instance->set_mesh(cloned);
	for (int64_t i = 0; i < blend_values.size(); ++i) instance->set_blend_shape_value(static_cast<int>(i), blend_values[i]);
	mesh_instance_id = previous_instance;
	return true;
}

PackedFloat32Array LimbMap::get_vertex_weight_color_for_bone(const StringName &) const { return PackedFloat32Array(); }

PackedFloat32Array LimbMap::get_vertex_weight_color_for_limb(const StringName &, double) const {
	PackedFloat32Array result;
	result.resize(get_vertex_num());
	result.fill(0.0f);
	return result;
}

bool LimbMap::has_any_matching_names(const PackedStringArray &one, const PackedStringArray &two) {
	for (int64_t i = 0; i < one.size(); ++i) if (two.has(one[i])) return true;
	return false;
}

bool LimbMap::has_any_matching_ints(const PackedInt32Array &one, const PackedInt32Array &two) {
	for (int64_t i = 0; i < one.size(); ++i) if (two.has(one[i])) return true;
	return false;
}

}
