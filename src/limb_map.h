#pragma once

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/skeleton3d.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

namespace godot {

// Skeleton queries and vertex masks use Godot's surface order followed by vertex
// order within each surface. Stored mesh resources are never modified in place.
class LimbMap : public Resource {
	GDCLASS(LimbMap, Resource)

	uint64_t skeleton_id = 0;
	uint64_t mesh_instance_id = 0;
	PackedStringArray exclude;
	PackedFloat32Array weights_for_indices(const PackedInt32Array &indices) const;
	PackedFloat32Array mask_for_indices(const PackedInt32Array &indices, double threshold) const;
	void append_descendants(int bone, PackedInt32Array &out, bool apply_exclusions) const;

protected:
	static void _bind_methods();

public:
	LimbMap();
	static Ref<LimbMap> get_limb_map(const Ref<LimbMap> &map);
	bool initialize(Skeleton3D *skeleton, MeshInstance3D *mesh = nullptr);
	Skeleton3D *get_skeleton() const;
	MeshInstance3D *get_mesh_instance() const;
	void set_exclude(const PackedStringArray &value);
	PackedStringArray get_exclude() const;
	bool has_excluded_keyword(const String &name) const;
	bool is_bone_excluded(const StringName &bone) const;
	int get_vertex_num() const;
	StringName get_bone_name(int index) const;
	int get_bone_index(const StringName &bone) const;
	PackedInt32Array get_all_child_bones(int index) const;
	PackedStringArray get_child_bones(const StringName &bone) const;
	PackedInt32Array get_direct_child_bones(int index) const;
	StringName get_direct_child_bone(const StringName &bone) const;
	PackedStringArray get_bone_path_to_root(const StringName &bone) const;
	Transform3D get_bone_reference_transform(const StringName &bone) const;
	PackedInt32Array get_limb_indices(const StringName &bone) const;
	PackedStringArray get_all_bones_of_limb(const StringName &bone) const;
	PackedInt32Array get_all_immediate_bones(const StringName &bone) const;
	Dictionary get_limb(const StringName &bone) const;
	PackedInt32Array remove_excluded_bones(const PackedInt32Array &bones) const;
	PackedStringArray convert_bones_to_names(const PackedInt32Array &bones) const;
	int get_mapped_bone_index(int skin_bind_index) const;
	PackedInt32Array get_mapped_bone_indices(const PackedInt32Array &skin_bind_indices) const;
	int get_mapped_raw_bone_index(int skeleton_bone_index) const;
	int get_raw_bone_index(int skeleton_bone_index) const;
	Dictionary get_vertex_influences(int vertex_index) const;
	int get_bone_with_most_influence(int vertex_index) const;
	bool has_bone_weight(int vertex_index, int bone_index, double threshold = 0.5) const;
	double get_weight(int vertex_index, int bone_index) const;
	PackedInt32Array get_all_bones_with_influence(int vertex_index, double threshold = 0.5) const;
	PackedFloat32Array get_weights_of_bone(const StringName &bone) const;
	PackedFloat32Array get_mask_of_bone(const StringName &bone, double threshold = 0.25) const;
	PackedFloat32Array get_weights_of_limb(const StringName &bone) const;
	PackedFloat32Array get_mask_of_limb(const StringName &bone, double threshold = 0.25) const;
	PackedFloat32Array get_mask_of_immediate_limb(const StringName &bone, double threshold = 0.25, bool include_bone = true) const;
	PackedInt32Array get_all_limb_vertices(const StringName &bone) const;
	bool set_limb_weights(MeshInstance3D *mesh, const StringName &bone, double threshold = 0.25);
	// Retained legacy results match the deprecated source functions.
	PackedFloat32Array get_vertex_weight_color_for_bone(const StringName &bone) const;
	PackedFloat32Array get_vertex_weight_color_for_limb(const StringName &bone, double threshold = 0.5) const;
	static bool has_any_matching_names(const PackedStringArray &one, const PackedStringArray &two);
	static bool has_any_matching_ints(const PackedInt32Array &one, const PackedInt32Array &two);
};

}
