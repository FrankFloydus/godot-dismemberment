#include "mesh_partition.h"

#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/skin.hpp>
#include <godot_cpp/classes/skin_reference.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <algorithm>
#include <cmath>
#include <vector>

namespace godot {
namespace {

constexpr float SNAPSHOT_BLEND_EPSILON = 0.0001f;

template <class Packed>
Variant compact_values(const Variant &value, const std::vector<int> &vertices, int vertex_count) {
    Packed input = value;
    if (input.is_empty() || vertex_count <= 0 || input.size() % vertex_count != 0) return Variant();
    const int stride = int(input.size() / vertex_count);
    Packed output;
    output.resize(int64_t(vertices.size()) * stride);
    for (size_t i = 0; i < vertices.size(); ++i) {
        for (int j = 0; j < stride; ++j) output.set(int64_t(i) * stride + j, input[int64_t(vertices[i]) * stride + j]);
    }
    return output;
}

Variant compact_channel(const Variant &value, const std::vector<int> &vertices, int vertex_count) {
    switch (value.get_type()) {
        case Variant::PACKED_VECTOR3_ARRAY: return compact_values<PackedVector3Array>(value, vertices, vertex_count);
        case Variant::PACKED_VECTOR2_ARRAY: return compact_values<PackedVector2Array>(value, vertices, vertex_count);
        case Variant::PACKED_COLOR_ARRAY: return compact_values<PackedColorArray>(value, vertices, vertex_count);
        case Variant::PACKED_FLOAT32_ARRAY: return compact_values<PackedFloat32Array>(value, vertices, vertex_count);
        case Variant::PACKED_INT32_ARRAY: return compact_values<PackedInt32Array>(value, vertices, vertex_count);
        case Variant::PACKED_BYTE_ARRAY: return compact_values<PackedByteArray>(value, vertices, vertex_count);
        default: return Variant();
    }
}

struct CompactSurface {
    Array arrays;
    std::vector<int> vertices;
    std::vector<int> mapping;
};

CompactSurface compact_surface(const Array &source, const std::vector<int> &triangle_indices, int vertex_count,
        const std::vector<std::vector<int>> &lod_indices = {}) {
    CompactSurface result;
    result.arrays.resize(Mesh::ARRAY_MAX);
    result.mapping.resize(vertex_count, -1);
    PackedInt32Array indices;
    indices.resize(triangle_indices.size());
    for (size_t i = 0; i < triangle_indices.size(); ++i) {
        const int old_index = triangle_indices[i];
        if (result.mapping[old_index] < 0) {
            result.mapping[old_index] = int(result.vertices.size());
            result.vertices.push_back(old_index);
        }
        indices.set(i, result.mapping[old_index]);
    }
    // Simplified LODs can reference vertices not present in the base triangle
    // subset. Include those vertices before compacting every attribute channel.
    for (const std::vector<int> &lod : lod_indices) {
        for (int old_index : lod) {
            if (result.mapping[old_index] < 0) {
                result.mapping[old_index] = int(result.vertices.size());
                result.vertices.push_back(old_index);
            }
        }
    }
    for (int channel = 0; channel < Mesh::ARRAY_INDEX; ++channel) {
        result.arrays[channel] = compact_channel(source[channel], result.vertices, vertex_count);
    }
    result.arrays[Mesh::ARRAY_INDEX] = indices;
    return result;
}

struct PartitionedLOD {
    double distance;
    std::vector<int> remaining;
    std::vector<int> detached;
};

void classify_triangles(const PackedInt32Array &indices, int vertex_count,
        const std::vector<bool> &selected, std::vector<int> &remaining, std::vector<int> &detached,
        bool implicit_indices = false) {
    const int element_count = implicit_indices ? vertex_count : indices.size();
    for (int element = 0; element + 2 < element_count; element += 3) {
        int triangle[3];
        int votes = 0;
        bool valid = true;
        for (int corner = 0; corner < 3; ++corner) {
            triangle[corner] = implicit_indices ? element + corner : indices[element + corner];
            if (triangle[corner] < 0 || triangle[corner] >= vertex_count) { valid = false; break; }
            if (selected[triangle[corner]]) ++votes;
        }
        if (!valid) continue;
        std::vector<int> &destination = votes >= 2 ? detached : remaining;
        destination.insert(destination.end(), triangle, triangle + 3);
    }
}

std::vector<PartitionedLOD> partition_lods(const Array &serialized_surfaces, int surface,
        int vertex_count, const std::vector<bool> &selected) {
    std::vector<PartitionedLOD> result;
    if (surface >= serialized_surfaces.size() || serialized_surfaces[surface].get_type() != Variant::DICTIONARY) return result;
    const Dictionary data = serialized_surfaces[surface];
    if (!data.has("lods") || data["lods"].get_type() != Variant::ARRAY) return result;
    // ArrayMesh's storage format is [distance, packed index bytes, ...]. The
    // public RenderingServer method returned malformed LODs on Godot 4.3.
    const Array lods = data["lods"];
    const int stride = vertex_count <= 65536 ? 2 : 4;
    for (int i = 0; i + 1 < lods.size(); i += 2) {
        if (lods[i + 1].get_type() != Variant::PACKED_BYTE_ARRAY) continue;
        const PackedByteArray bytes = lods[i + 1];
        if (bytes.size() % stride != 0) continue;
        PackedInt32Array indices;
        indices.resize(bytes.size() / stride);
        for (int index = 0; index < indices.size(); ++index) {
            uint32_t value = 0;
            for (int byte = 0; byte < stride; ++byte) value |= uint32_t(bytes[index * stride + byte]) << (byte * 8);
            indices.set(index, int32_t(value));
        }
        PartitionedLOD lod;
        lod.distance = lods[i];
        classify_triangles(indices, vertex_count, selected, lod.remaining, lod.detached);
        result.push_back(std::move(lod));
    }
    return result;
}

Dictionary compact_lods(const std::vector<PartitionedLOD> &lods,
        const CompactSurface &surface, bool detached) {
    Dictionary result;
    const PackedInt32Array base_indices = surface.arrays[Mesh::ARRAY_INDEX];
    for (const PartitionedLOD &lod : lods) {
        const std::vector<int> &source_indices = detached ? lod.detached : lod.remaining;
        if (source_indices.empty() || source_indices.size() >= size_t(base_indices.size())) continue;
        PackedInt32Array indices;
        indices.resize(source_indices.size());
        for (size_t i = 0; i < source_indices.size(); ++i) indices.set(i, surface.mapping[source_indices[i]]);
        result[lod.distance] = indices;
    }
    return result;
}

TypedArray<Array> compact_blends(const TypedArray<Array> &source,
        const std::vector<int> &vertices, int vertex_count) {
    TypedArray<Array> output;
    for (int i = 0; i < source.size(); ++i) {
        Array blend_source = source[i];
        Array blend;
        blend.resize(Mesh::ARRAY_MAX);
        for (int channel = Mesh::ARRAY_VERTEX; channel <= Mesh::ARRAY_TANGENT; ++channel) {
            if (channel < blend_source.size()) blend[channel] = compact_channel(blend_source[channel], vertices, vertex_count);
        }
        output.push_back(blend);
    }
    return output;
}

int mapped_bone(const Ref<Skin> &skin, Skeleton3D *skeleton, int index) {
    if (skin.is_null()) return index < skeleton->get_bone_count() ? index : -1;
    if (index < 0 || index >= skin->get_bind_count()) return -1;
    const StringName name = skin->get_bind_name(index);
    return name != StringName() ? skeleton->find_bone(name) : skin->get_bind_bone(index);
}

bool belongs_to_limb(Skeleton3D *skeleton, int bone, int root) {
    while (bone >= 0 && bone < skeleton->get_bone_count()) {
        if (bone == root) return true;
        bone = skeleton->get_bone_parent(bone);
    }
    return false;
}

// Apply the current blend mix before skinning. NORMALIZED arrays contain target
// positions; RELATIVE arrays contain offsets. The remaining mesh retains its
// original blend channels so it can continue animating after the partition.
Array blended_arrays(const Array &base, const TypedArray<Array> &shapes,
        MeshInstance3D *instance, bool relative, bool strict = false) {
    if (strict && shapes.size() != instance->get_blend_shape_count()) return {};
    Array output = base.duplicate();
    if (shapes.is_empty()) return output;
    PackedVector3Array positions = base[Mesh::ARRAY_VERTEX];
    PackedVector3Array normals = base[Mesh::ARRAY_NORMAL];
    PackedFloat32Array tangents = base[Mesh::ARRAY_TANGENT];
    const PackedVector3Array base_positions = positions;
    const PackedVector3Array base_normals = normals;
    const PackedFloat32Array base_tangents = tangents;
    for (int shape_index = 0; shape_index < shapes.size() && shape_index < instance->get_blend_shape_count(); ++shape_index) {
        const float weight = instance->get_blend_shape_value(shape_index);
        if (std::abs(weight) <= (strict ? SNAPSHOT_BLEND_EPSILON : 0.000001f)) continue;
        const Array shape = shapes[shape_index];
        if (shape.size() < Mesh::ARRAY_MAX) {
            if (strict) return {};
            continue;
        }
        const PackedVector3Array shape_positions = shape[Mesh::ARRAY_VERTEX];
        const PackedVector3Array shape_normals = shape[Mesh::ARRAY_NORMAL];
        const PackedFloat32Array shape_tangents = shape[Mesh::ARRAY_TANGENT];
        if (strict && (shape_positions.size() != positions.size() ||
                shape_normals.size() != normals.size() || shape_tangents.size() != tangents.size())) return {};
        if (shape_positions.size() == positions.size()) {
            for (int vertex = 0; vertex < positions.size(); ++vertex) {
                positions.set(vertex, positions[vertex] + (shape_positions[vertex] - (relative ? Vector3() : base_positions[vertex])) * weight);
            }
        }
        if (shape_normals.size() == normals.size()) {
            for (int vertex = 0; vertex < normals.size(); ++vertex) {
                normals.set(vertex, normals[vertex] + (shape_normals[vertex] - (relative ? Vector3() : base_normals[vertex])) * weight);
            }
        }
        if (shape_tangents.size() == tangents.size()) {
            for (int element = 0; element < tangents.size(); ++element) {
                // Tangent handedness is discrete and is retained from the base.
                if (element % 4 == 3) continue;
                tangents.set(element, tangents[element] + (shape_tangents[element] - (relative ? 0.0f : base_tangents[element])) * weight);
            }
        }
    }
    if (strict) {
        Vector3 *normal_data = normals.ptrw();
        for (int64_t vertex = 0; vertex < normals.size(); ++vertex) normal_data[vertex] = normal_data[vertex].normalized();
        float *tangent_data = tangents.ptrw();
        for (int64_t offset = 0; offset < tangents.size(); offset += 4) {
            const Vector3 direction = Vector3(tangent_data[offset], tangent_data[offset + 1], tangent_data[offset + 2]).normalized();
            tangent_data[offset] = direction.x;
            tangent_data[offset + 1] = direction.y;
            tangent_data[offset + 2] = direction.z;
        }
    }
    output[Mesh::ARRAY_VERTEX] = positions;
    if (!normals.is_empty()) output[Mesh::ARRAY_NORMAL] = normals;
    if (!tangents.is_empty()) output[Mesh::ARRAY_TANGENT] = tangents;
    return output;
}

struct SkinBind {
    Transform3D transform;
    Basis normal_basis;
    bool valid = false;
    bool valid_normal = false;
};

SkinBind make_skin_bind(const Transform3D &transform, bool match_renderer) {
    SkinBind bind;
    bind.transform = transform;
    bind.valid = true;
    if (match_renderer) {
        bind.normal_basis = transform.basis;
        bind.valid_normal = true;
    } else if (std::abs(transform.basis.determinant()) > 0.00000001) {
        bind.normal_basis = transform.basis.inverse().transposed();
        bind.valid_normal = true;
    }
    return bind;
}

bool bake_skin_arrays(Array &arrays, const std::vector<SkinBind> &palette, bool snapshot) {
    PackedVector3Array positions = arrays[Mesh::ARRAY_VERTEX];
    PackedVector3Array normals = arrays[Mesh::ARRAY_NORMAL];
    PackedFloat32Array tangents = arrays[Mesh::ARRAY_TANGENT];
    const PackedInt32Array bones = arrays[Mesh::ARRAY_BONES];
    const PackedFloat32Array weights = arrays[Mesh::ARRAY_WEIGHTS];
    const int vertex_count = positions.size();
    if (vertex_count == 0 || bones.size() != weights.size() || bones.size() % vertex_count != 0) return false;
    const int influence_count = bones.size() / vertex_count;
    if (influence_count != 4 && influence_count != 8) return false;
    Vector3 *position_data = positions.ptrw();
    Vector3 *normal_data = normals.size() == vertex_count ? normals.ptrw() : nullptr;
    float *tangent_data = tangents.size() == int64_t(vertex_count) * 4 ? tangents.ptrw() : nullptr;
    const int32_t *bone_data = bones.ptr();
    const float *weight_data = weights.ptr();
    for (int vertex = 0; vertex < vertex_count; ++vertex) {
        Vector3 position, normal, tangent;
        const Vector3 input_position = position_data[vertex];
        const Vector3 input_normal = normal_data ? normal_data[vertex] : Vector3();
        const int64_t tangent_offset = int64_t(vertex) * 4;
        const Vector3 input_tangent = tangent_data ?
                Vector3(tangent_data[tangent_offset], tangent_data[tangent_offset + 1], tangent_data[tangent_offset + 2]) : Vector3();
        double total_weight = 0.0;
        for (int influence = 0; influence < influence_count; ++influence) {
            const int64_t element = int64_t(vertex) * influence_count + influence;
            const double weight = weight_data[element];
            if (weight == 0.0) continue;
            const int index = bone_data[element];
            if (weight < 0.0 || index < 0 || size_t(index) >= palette.size() || !palette[index].valid ||
                    (snapshot && !std::isfinite(weight))) {
                if (snapshot) return false;
                continue;
            }
            const SkinBind &bind = palette[index];
            position += bind.transform.xform(input_position) * weight;
            if (normal_data && bind.valid_normal) normal += bind.normal_basis.xform(input_normal) * weight;
            if (tangent_data) tangent += bind.transform.basis.xform(input_tangent) * weight;
            total_weight += weight;
        }
        if (total_weight <= 0.000001) {
            if (snapshot) return false;
            continue;
        }
        // Godot's 3D skin shader uses the packed weights directly. The older
        // partition path retains its weight normalization for compatibility.
        if (snapshot && (!position.is_finite() || !normal.is_finite() || !tangent.is_finite())) return false;
        position_data[vertex] = snapshot ? position : position / total_weight;
        if (normal_data) normal_data[vertex] = snapshot && normal.is_zero_approx() ? input_normal : normal.normalized();
        if (tangent_data) {
            tangent = snapshot && tangent.is_zero_approx() ? input_tangent : tangent.normalized();
            tangent_data[tangent_offset] = tangent.x;
            tangent_data[tangent_offset + 1] = tangent.y;
            tangent_data[tangent_offset + 2] = tangent.z;
        }
    }
    arrays[Mesh::ARRAY_VERTEX] = positions;
    if (!normals.is_empty()) arrays[Mesh::ARRAY_NORMAL] = normals;
    if (!tangents.is_empty()) arrays[Mesh::ARRAY_TANGENT] = tangents;
    arrays[Mesh::ARRAY_BONES] = Variant();
    arrays[Mesh::ARRAY_WEIGHTS] = Variant();
    return true;
}

void bake_skin(Array &arrays, const Ref<Skin> &skin, Skeleton3D *skeleton,
        MeshInstance3D *instance) {
    const Transform3D mesh_from_skeleton = instance->get_global_transform().affine_inverse() * skeleton->get_global_transform();
    const Transform3D skeleton_from_mesh = mesh_from_skeleton.affine_inverse();
    const int bind_count = skin.is_valid() ? skin->get_bind_count() : skeleton->get_bone_count();
    std::vector<SkinBind> palette(bind_count);
    for (int bind = 0; bind < bind_count; ++bind) {
        const int bone = mapped_bone(skin, skeleton, bind);
        if (bone < 0 || bone >= skeleton->get_bone_count()) continue;
        const Transform3D inverse_bind = skin.is_valid() ? skin->get_bind_pose(bind) :
                skeleton->get_bone_global_rest(bone).affine_inverse() * skeleton_from_mesh;
        palette[bind] = make_skin_bind(mesh_from_skeleton * skeleton->get_bone_global_pose(bone) * inverse_bind, false);
    }
    bake_skin_arrays(arrays, palette, false);
}

std::vector<SkinBind> snapshot_palette(MeshInstance3D *mesh, Skeleton3D *skeleton,
        const PackedStringArray &collapsed_roots) {
    if (!skeleton || skeleton->get_bone_count() == 0) return {};
    Ref<Skin> skin = mesh->get_skin();
    const Ref<SkinReference> reference = mesh->get_skin_reference();
    RID palette_rid;
    if (reference.is_valid()) {
        const NodePath skeleton_path = mesh->get_skeleton_path();
        if (!skeleton_path.is_empty() && mesh->get_node_or_null(skeleton_path) != skeleton) return {};
        skin = reference->get_skin();
        palette_rid = reference->get_skeleton();
    }
    const int bind_count = skin.is_valid() ? skin->get_bind_count() : skeleton->get_bone_count();
    RenderingServer *renderer = RenderingServer::get_singleton();
    const bool use_rendered_pose = renderer && palette_rid.is_valid() && renderer->skeleton_get_bone_count(palette_rid) == bind_count;
    std::vector<bool> collapsed;
    if (!collapsed_roots.is_empty()) {
        collapsed.resize(skeleton->get_bone_count());
        for (const String &name : collapsed_roots) {
            const int root = skeleton->find_bone(name);
            if (root >= 0) collapsed[root] = true;
        }
    }
    const Basis zero_basis{ Vector3(), Vector3(), Vector3() };
    // Fully collapsed vertices coincide. A millimetre-scale copy
    // preserves a closed surface for cutting without restoring a missing limb.
    const Basis compressed_basis = Basis::from_scale(Vector3(0.001, 0.001, 0.001));
    std::vector<SkinBind> palette(bind_count);
    for (int slot = 0; slot < bind_count; ++slot) {
        const int bone = mapped_bone(skin, skeleton, slot);
        if (bone < 0 || bone >= skeleton->get_bone_count()) continue;
        // The 3D renderer applies its bind palette in mesh-local coordinates.
        // Instance placement is applied later, even when the nodes have different transforms.
        Transform3D transform;
        if (use_rendered_pose) {
            transform = renderer->skeleton_bone_get_transform(palette_rid, slot);
        } else {
            const Transform3D rest = skeleton->get_bone_global_rest(bone);
            if (skin.is_null() && (rest.basis.determinant() == 0.0 || !rest.is_finite())) continue;
            const Transform3D inverse_bind = skin.is_valid() ? skin->get_bind_pose(slot) : rest.affine_inverse();
            transform = skeleton->get_bone_global_pose(bone) * inverse_bind;
        }
        if (!collapsed.empty()) {
            int collapsed_root = -1;
            for (int ancestor = bone; ancestor >= 0; ancestor = skeleton->get_bone_parent(ancestor)) {
                if (collapsed[ancestor]) collapsed_root = ancestor;
            }
            if (collapsed_root >= 0) {
                // The renderer records the cut pivot in the origin of its zero basis.
                // Headless renderers may provide no skin palette.
                if (!use_rendered_pose || transform.basis != zero_basis) {
                    transform.origin = skeleton->get_bone_global_pose(collapsed_root).origin;
                }
                transform.basis = compressed_basis;
            }
        }
        if (transform.is_finite()) palette[slot] = make_skin_bind(transform, true);
    }
    return palette;
}

}

void MeshPartition::_bind_methods() {
    ClassDB::bind_static_method("MeshPartition", D_METHOD("isolate_limb", "mesh", "skeleton", "bone", "threshold", "bake_pose"),
            &MeshPartition::isolate_limb, DEFVAL(0.5), DEFVAL(true));
    ClassDB::bind_static_method("MeshPartition", D_METHOD("get_surface_lods", "mesh", "surface"), &MeshPartition::get_surface_lods);
    ClassDB::bind_static_method("MeshPartition", D_METHOD("snapshot_pose", "mesh", "skeleton", "collapsed_roots"),
            &MeshPartition::snapshot_pose, DEFVAL(PackedStringArray()));
}

Ref<ArrayMesh> MeshPartition::snapshot_pose(MeshInstance3D *instance, Skeleton3D *skeleton,
        const PackedStringArray &collapsed_roots) {
    std::vector<MeshPoseSurface> surfaces;
    if (!snapshot_pose_surfaces(instance, skeleton, surfaces, collapsed_roots)) return {};

    Ref<ArrayMesh> output;
    output.instantiate();
    for (int i = 0; i < int(surfaces.size()); ++i) {
        const MeshPoseSurface &surface = surfaces[i];
        output->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, surface.arrays, {}, {}, BitField<Mesh::ArrayFormat>(surface.format_flags));
        if (output->get_surface_count() != i + 1) return {};
        output->surface_set_material(i, surface.material);
        output->surface_set_name(i, surface.name);
    }
    return output;
}

bool MeshPartition::snapshot_pose_surfaces(MeshInstance3D *instance, Skeleton3D *skeleton, std::vector<MeshPoseSurface> &surfaces,
        const PackedStringArray &collapsed_roots) {
    if (!instance) return false;
    const Ref<ArrayMesh> source = instance->get_mesh();
    if (source.is_null() || source->get_surface_count() == 0) return false;

    bool active_blends = false;
    for (int blend = 0; blend < source->get_blend_shape_count(); ++blend) {
        const float weight = instance->get_blend_shape_value(blend);
        if (!std::isfinite(weight)) return false;
        active_blends |= std::abs(weight) > SNAPSHOT_BLEND_EPSILON;
    }
    const bool relative_blends = source->get_blend_shape_mode() == Mesh::BLEND_SHAPE_MODE_RELATIVE;
    const uint64_t skin_channels = Mesh::ARRAY_FORMAT_BONES | Mesh::ARRAY_FORMAT_WEIGHTS;
    const uint64_t retained_flags = (uint64_t(0xfff) << Mesh::ARRAY_FORMAT_CUSTOM_BASE) | Mesh::ARRAY_FLAG_USE_DYNAMIC_UPDATE;
    std::vector<SkinBind> palette;
    const int surface_count = source->get_surface_count();
    std::vector<MeshPoseSurface> captured;
    captured.reserve(surface_count);
    for (int surface = 0; surface < surface_count; ++surface) {
        if (source->surface_get_primitive_type(surface) != Mesh::PRIMITIVE_TRIANGLES) return false;
        const uint64_t format = source->surface_get_format(surface);
        Array arrays = source->surface_get_arrays(surface);
        if (arrays.size() != Mesh::ARRAY_MAX || arrays[Mesh::ARRAY_VERTEX].get_type() != Variant::PACKED_VECTOR3_ARRAY) return false;
        const PackedVector3Array positions = arrays[Mesh::ARRAY_VERTEX];
        const PackedVector3Array normals = arrays[Mesh::ARRAY_NORMAL];
        const PackedFloat32Array tangents = arrays[Mesh::ARRAY_TANGENT];
        const PackedInt32Array indices = arrays[Mesh::ARRAY_INDEX];
        const int64_t vertex_count = positions.size();
        if (vertex_count < 3 || (!normals.is_empty() && normals.size() != vertex_count) ||
                (!tangents.is_empty() && tangents.size() != vertex_count * 4) ||
                (indices.is_empty() ? vertex_count : indices.size()) % 3 != 0) return false;
        for (int32_t index : indices) if (index < 0 || index >= vertex_count) return false;

        if (active_blends) {
            arrays = blended_arrays(arrays, source->surface_get_blend_shape_arrays(surface), instance, relative_blends, true);
            if (arrays.is_empty()) return false;
        }
        const uint64_t surface_skin = format & skin_channels;
        if (surface_skin != 0) {
            if (surface_skin != skin_channels) return false;
            if (palette.empty()) palette = snapshot_palette(instance, skeleton, collapsed_roots);
            if (palette.empty() || !bake_skin_arrays(arrays, palette, true)) return false;
        } else {
            const PackedVector3Array posed_positions = arrays[Mesh::ARRAY_VERTEX];
            for (const Vector3 &position : posed_positions) if (!position.is_finite()) return false;
        }
        captured.push_back({ std::move(arrays), instance->get_active_material(surface), source->surface_get_name(surface), format & retained_flags });
    }
    surfaces = std::move(captured);
    return true;
}

Dictionary MeshPartition::get_surface_lods(const Ref<ArrayMesh> &mesh, int surface) {
    Dictionary result;
    if (mesh.is_null() || surface < 0 || surface >= mesh->get_surface_count()) return result;
    const Variant storage = mesh->get("_surfaces");
    if (storage.get_type() != Variant::ARRAY) return result;
    const Array surfaces = storage;
    if (surface >= surfaces.size() || surfaces[surface].get_type() != Variant::DICTIONARY) return result;
    const Dictionary data = surfaces[surface];
    if (!data.has("lods") || data["lods"].get_type() != Variant::ARRAY) return result;
    const Array raw_lods = data["lods"];
    const int vertex_count = mesh->surface_get_array_len(surface);
    const int stride = vertex_count <= 65536 ? 2 : 4;
    for (int i = 0; i + 1 < raw_lods.size(); i += 2) {
        if (raw_lods[i + 1].get_type() != Variant::PACKED_BYTE_ARRAY) continue;
        const PackedByteArray bytes = raw_lods[i + 1];
        if (bytes.size() % stride != 0) continue;
        PackedInt32Array indices;
        indices.resize(bytes.size() / stride);
        for (int index = 0; index < indices.size(); ++index) {
            uint32_t value = 0;
            for (int byte = 0; byte < stride; ++byte) value |= uint32_t(bytes[index * stride + byte]) << (byte * 8);
            indices.set(index, int32_t(value));
        }
        result[raw_lods[i]] = indices;
    }
    return result;
}

Dictionary MeshPartition::isolate_limb(MeshInstance3D *instance, Skeleton3D *skeleton,
        const StringName &bone, double threshold, bool bake_pose) {
    Dictionary result;
    Ref<ArrayMesh> remaining;
    Ref<ArrayMesh> detached;
    remaining.instantiate();
    detached.instantiate();
    result["remaining_mesh"] = remaining;
    result["detached_mesh"] = detached;
    result["remaining_triangle_count"] = 0;
    result["detached_triangle_count"] = 0;
    if (!instance || !skeleton || instance->get_mesh().is_null()) {
        result["error"] = "A source mesh and Skeleton3D are required.";
        return result;
    }
    const int root = skeleton->find_bone(bone);
    if (root < 0) {
        result["error"] = "Bone was not found on the skeleton.";
        return result;
    }
    const Ref<Mesh> source = instance->get_mesh();
    const Ref<ArrayMesh> source_array = source;
    const Ref<Skin> skin = instance->get_skin();
    Array serialized_surfaces;
    if (source_array.is_valid()) {
        const Variant storage = source_array->get("_surfaces");
        if (storage.get_type() == Variant::ARRAY) serialized_surfaces = storage;
    }
    bool relative = false;
    if (source_array.is_valid()) {
        relative = source_array->get_blend_shape_mode() == Mesh::BLEND_SHAPE_MODE_RELATIVE;
        remaining->set_blend_shape_mode(source_array->get_blend_shape_mode());
        if (!bake_pose) detached->set_blend_shape_mode(source_array->get_blend_shape_mode());
        for (int blend = 0; blend < source_array->get_blend_shape_count(); ++blend) {
            remaining->add_blend_shape(source_array->get_blend_shape_name(blend));
            if (!bake_pose) detached->add_blend_shape(source_array->get_blend_shape_name(blend));
        }
    }
    int remaining_triangles = 0;
    int detached_triangles = 0;
    int unsupported_surfaces = 0;
    threshold = std::clamp(threshold, 0.0, 1.0);
    for (int surface = 0; surface < source->get_surface_count(); ++surface) {
        if (source_array.is_valid() && source_array->surface_get_primitive_type(surface) != Mesh::PRIMITIVE_TRIANGLES) {
            ++unsupported_surfaces;
            continue;
        }
        const Array arrays = source->surface_get_arrays(surface);
        if (arrays.size() != Mesh::ARRAY_MAX) continue;
        const PackedVector3Array positions = arrays[Mesh::ARRAY_VERTEX];
        const PackedInt32Array bones = arrays[Mesh::ARRAY_BONES];
        const PackedFloat32Array weights = arrays[Mesh::ARRAY_WEIGHTS];
        const PackedInt32Array indices = arrays[Mesh::ARRAY_INDEX];
        const int vertex_count = positions.size();
        if (!vertex_count) continue;
        const int influence_count = bones.size() % vertex_count == 0 ? bones.size() / vertex_count : 0;
        const bool valid_weights = (influence_count == 4 || influence_count == 8) && weights.size() == bones.size();
        std::vector<bool> selected(vertex_count, false);
        if (valid_weights) {
            for (int vertex = 0; vertex < vertex_count; ++vertex) {
                double limb_weight = 0;
                for (int influence = 0; influence < influence_count; ++influence) {
                    const int element = vertex * influence_count + influence;
                    const int skeleton_bone = mapped_bone(skin, skeleton, bones[element]);
                    if (belongs_to_limb(skeleton, skeleton_bone, root)) limb_weight += weights[element];
                }
                selected[vertex] = limb_weight > 0 && limb_weight >= threshold;
            }
        }
        std::vector<int> keep_indices, cut_indices;
        classify_triangles(indices, vertex_count, selected, keep_indices, cut_indices, indices.is_empty());
        const std::vector<PartitionedLOD> lods = partition_lods(serialized_surfaces, surface, vertex_count, selected);
        std::vector<std::vector<int>> remaining_lod_indices, detached_lod_indices;
        for (const PartitionedLOD &lod : lods) {
            if (lod.remaining.size() < keep_indices.size()) remaining_lod_indices.push_back(lod.remaining);
            if (lod.detached.size() < cut_indices.size()) detached_lod_indices.push_back(lod.detached);
        }
        const TypedArray<Array> blend_arrays = source->surface_get_blend_shape_arrays(surface);
        uint64_t flags = 0;
        if (source_array.is_valid()) {
            const uint64_t format = source_array->surface_get_format(surface);
            // Preserve custom channel formats and dynamic flags, not array-presence bits.
            flags = format & ((uint64_t(0xfff) << Mesh::ARRAY_FORMAT_CUSTOM_BASE) | Mesh::ARRAY_FLAG_USE_DYNAMIC_UPDATE);
        }
        if (influence_count == 8) flags |= Mesh::ARRAY_FLAG_USE_8_BONE_WEIGHTS;
        if (!keep_indices.empty()) {
            CompactSurface compact = compact_surface(arrays, keep_indices, vertex_count, remaining_lod_indices);
            remaining->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, compact.arrays,
                    compact_blends(blend_arrays, compact.vertices, vertex_count), compact_lods(lods, compact, false), BitField<Mesh::ArrayFormat>(flags));
            remaining->surface_set_material(remaining->get_surface_count() - 1, instance->get_active_material(surface));
            if (source_array.is_valid()) remaining->surface_set_name(remaining->get_surface_count() - 1, source_array->surface_get_name(surface));
        }
        if (!cut_indices.empty()) {
            Array cut_source = bake_pose ? blended_arrays(arrays, blend_arrays, instance, relative) : arrays;
            CompactSurface compact = compact_surface(cut_source, cut_indices, vertex_count, detached_lod_indices);
            TypedArray<Array> cut_blends;
            uint64_t cut_flags = flags;
            if (bake_pose) {
                bake_skin(compact.arrays, skin, skeleton, instance);
                cut_flags &= ~uint64_t(Mesh::ARRAY_FLAG_USE_8_BONE_WEIGHTS);
            } else {
                cut_blends = compact_blends(blend_arrays, compact.vertices, vertex_count);
            }
            detached->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, compact.arrays,
                    cut_blends, compact_lods(lods, compact, true), BitField<Mesh::ArrayFormat>(cut_flags));
            detached->surface_set_material(detached->get_surface_count() - 1, instance->get_active_material(surface));
            if (source_array.is_valid()) detached->surface_set_name(detached->get_surface_count() - 1, source_array->surface_get_name(surface));
        }
        remaining_triangles += int(keep_indices.size() / 3);
        detached_triangles += int(cut_indices.size() / 3);
    }
    result["remaining_triangle_count"] = remaining_triangles;
    result["detached_triangle_count"] = detached_triangles;
    result["unsupported_surface_count"] = unsupported_surfaces;
    result["detached_frame"] = "source_mesh_local";
    result["source_global_transform"] = instance->get_global_transform();
    return result;
}

}
