#include "mesh_plane_slice.h"

#include "mesh_partition.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/typed_array.hpp>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <limits>
#include <numeric>
#include <unordered_map>
#include <vector>

namespace godot {
namespace {

using EdgeKey = uint64_t;

EdgeKey edge_key(int a, int b) {
    return (uint64_t(std::min(a, b)) << 32) | uint32_t(std::max(a, b));
}

struct PositionHash {
    size_t operator()(const Vector3 &position) const {
        const std::hash<real_t> hash;
        size_t value = hash(position.x);
        value ^= hash(position.y) + 0x9e3779b9 + (value << 6) + (value >> 2);
        return value ^ (hash(position.z) + 0x9e3779b9 + (value << 6) + (value >> 2));
    }
};

// A nonzero direction denotes an edge with one incident face. A second face
// must consume the edge from the opposite direction.
bool record_edge(std::unordered_map<EdgeKey, int8_t> &edges, int a, int b) {
    if (a == b) return false;
    const int8_t direction = a < b ? 1 : -1;
    auto [entry, inserted] = edges.try_emplace(edge_key(a, b), direction);
    if (inserted) return true;
    if (entry->second != -direction) return false;
    entry->second = 0;
    return true;
}

// Closed topology has exactly one distinct edge for every two face edges.
// A flat table keeps those records contiguous even on large render meshes.
class TopologyEdges {
    static constexpr uint64_t FORWARD = 1;
    static constexpr uint64_t REVERSE = 2;
    static constexpr uint64_t PAIRED = FORWARD | REVERSE;

    std::vector<uint64_t> slots;
    size_t limit = 0;
    size_t used = 0;
    size_t open = 0;

public:
    bool reserve(size_t max_edges) {
        if (max_edges > slots.max_size() / 2) return false;
        const size_t needed = max_edges * 2;
        size_t capacity = 1;
        while (capacity < needed) {
            if (capacity > slots.max_size() / 2) return false;
            capacity *= 2;
        }
        slots.resize(capacity);
        limit = max_edges;
        return true;
    }

    bool record(int a, int b) {
        if (a == b) return false;
        // Welded indices fit in 31 bits each, leaving two bits for incidence.
        const uint64_t key = (uint64_t(std::min(a, b)) << 33) | (uint64_t(std::max(a, b)) << 2);
        const uint64_t direction = a < b ? FORWARD : REVERSE;
        uint64_t hash = key ^ (key >> 33);
        hash *= 0xff51afd7ed558ccdULL;
        hash ^= hash >> 33;
        hash *= 0xc4ceb9fe1a85ec53ULL;
        hash ^= hash >> 33;
        const size_t mask = slots.size() - 1;
        for (size_t index = size_t(hash) & mask; ; index = (index + 1) & mask) {
            uint64_t &entry = slots[index];
            if (entry == 0) {
                // This mesh already has too many unique edges to close.
                if (used == limit) return false;
                entry = key | direction;
                ++used;
                ++open;
                return true;
            }
            if ((entry & ~PAIRED) != key) continue;
            if ((entry & PAIRED) != (PAIRED ^ direction)) return false;
            entry = key | PAIRED;
            --open;
            return true;
        }
    }

    bool is_closed() const { return open == 0; }
};

bool has_area(const Vector3 &a, const Vector3 &b, const Vector3 &c) {
    const double x = double(b.x) - a.x, y = double(b.y) - a.y, z = double(b.z) - a.z;
    const double u = double(c.x) - a.x, v = double(c.y) - a.y, w = double(c.z) - a.z;
    return y * w != z * v || z * u != x * w || x * v != y * u;
}

template <class Packed>
bool read_channel(const Array &arrays, int index, int count, Packed &output) {
    const Variant value = arrays[index];
    if (value.get_type() == Variant::NIL) return true;
    if (value.get_type() != Variant(Packed()).get_type()) return false;
    output = value;
    return output.is_empty() || output.size() == count;
}

struct SurfaceInput {
    PackedVector3Array positions;
    PackedVector3Array normals;
    PackedFloat32Array tangents;
    PackedColorArray colors;
    PackedVector2Array uv;
    PackedVector2Array uv2;
    PackedInt32Array indices;
    std::vector<int> topology;
    Ref<Material> material;
    String name;

    bool read(const Array &arrays, const Ref<Material> &surface_material, const String &surface_name) {
        if (arrays.size() != Mesh::ARRAY_MAX || arrays[Mesh::ARRAY_VERTEX].get_type() != Variant::PACKED_VECTOR3_ARRAY) return false;
        for (int channel = Mesh::ARRAY_CUSTOM0; channel < Mesh::ARRAY_INDEX; ++channel) {
            if (arrays[channel].get_type() != Variant::NIL) return false;
        }
        positions = arrays[Mesh::ARRAY_VERTEX];
        if (positions.is_empty() || positions.size() > std::numeric_limits<int>::max() / 4) return false;
        const int count = int(positions.size());
        if (!read_channel(arrays, Mesh::ARRAY_NORMAL, count, normals) ||
                !read_channel(arrays, Mesh::ARRAY_TANGENT, count * 4, tangents) ||
                !read_channel(arrays, Mesh::ARRAY_COLOR, count, colors) ||
                !read_channel(arrays, Mesh::ARRAY_TEX_UV, count, uv) ||
                !read_channel(arrays, Mesh::ARRAY_TEX_UV2, count, uv2) ||
                (!tangents.is_empty() && normals.is_empty())) return false;
        if (arrays[Mesh::ARRAY_INDEX].get_type() == Variant::PACKED_INT32_ARRAY) {
            indices = arrays[Mesh::ARRAY_INDEX];
        } else if (arrays[Mesh::ARRAY_INDEX].get_type() != Variant::NIL) {
            return false;
        }
        if (element_count() % 3 != 0 || element_count() > std::numeric_limits<int>::max()) return false;
        material = surface_material;
        name = surface_name;
        return true;
    }

    int64_t element_count() const { return indices.is_empty() ? positions.size() : indices.size(); }
};

struct Vertex {
    Vector3 position;
    double distance;
    int side;
    int seam = -1;
};

// Retain each surface's original vertex or edge identity for UV and shading
// attributes. The seam index supplies a single exact position across surfaces.
struct Corner {
    int a = -1;
    int b = -1;
    int seam = -1;
    real_t fraction = 0;
};

struct SurfaceTriangles {
    std::vector<Corner> vertices;
    std::vector<int32_t> indices;
};

struct SurfaceSide {
    std::vector<int> original;
    std::unordered_map<EdgeKey, int> intersections;
    SurfaceTriangles triangles;

    explicit SurfaceSide(const SurfaceInput &surface) : original(surface.positions.size(), -1) {
        triangles.vertices.reserve(size_t(surface.positions.size()) / 2);
        triangles.indices.reserve(size_t(surface.element_count()) / 2);
    }

    int add_corner(const Corner &corner) {
        const int next = int(triangles.vertices.size());
        if (corner.b < 0) {
            int &index = original[corner.a];
            if (index < 0) {
                index = next;
                triangles.vertices.push_back(corner);
            }
            return index;
        }
        auto [entry, inserted] = intersections.try_emplace(edge_key(corner.a, corner.b), next);
        if (inserted) triangles.vertices.push_back(corner);
        return entry->second;
    }
};

struct SurfaceOutput {
    SurfaceSide positive;
    SurfaceSide negative;

    explicit SurfaceOutput(const SurfaceInput &surface) : positive(surface), negative(surface) {}
};

struct Point2 {
    double x;
    double y;
};

double orient(const Point2 &a, const Point2 &b, const Point2 &c) {
    return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
}

bool between(const Point2 &p, const Point2 &a, const Point2 &b) {
    return p.x >= std::min(a.x, b.x) && p.x <= std::max(a.x, b.x) &&
            p.y >= std::min(a.y, b.y) && p.y <= std::max(a.y, b.y);
}

bool segments_intersect(const Point2 &a, const Point2 &b, const Point2 &c, const Point2 &d) {
    const double abc = orient(a, b, c), abd = orient(a, b, d);
    const double cda = orient(c, d, a), cdb = orient(c, d, b);
    if ((abc == 0 && between(c, a, b)) || (abd == 0 && between(d, a, b)) ||
            (cda == 0 && between(a, c, d)) || (cdb == 0 && between(b, c, d))) return true;
    return ((abc > 0 && abd < 0) || (abc < 0 && abd > 0)) &&
            ((cda > 0 && cdb < 0) || (cda < 0 && cdb > 0));
}

bool contains_point(const std::vector<int> &loop, const std::vector<Point2> &points, const Point2 &p) {
    bool inside = false;
    for (size_t i = 0; i < loop.size(); ++i) {
        const Point2 &a = points[loop[i]];
        const Point2 &b = points[loop[(i + 1) % loop.size()]];
        if ((a.y > p.y) != (b.y > p.y) && p.x < a.x + (p.y - a.y) * (b.x - a.x) / (b.y - a.y)) {
            inside = !inside;
        }
    }
    return inside;
}

bool triangulate(const std::vector<int> &loop, const std::vector<Point2> &points, std::vector<int> &output) {
    std::vector<int> remaining(loop.rbegin(), loop.rend());
    while (remaining.size() > 3) {
        bool found = false;
        for (size_t i = 0; i < remaining.size(); ++i) {
            const int a = remaining[(i + remaining.size() - 1) % remaining.size()];
            const int b = remaining[i];
            const int c = remaining[(i + 1) % remaining.size()];
            if (orient(points[a], points[b], points[c]) <= 0) continue;
            bool blocked = false;
            for (int vertex : remaining) {
                if (vertex == a || vertex == b || vertex == c) continue;
                const Point2 &p = points[vertex];
                // Points on the diagonal also block the ear. Each collinear
                // boundary segment must survive so the cap meets the shell.
                if (orient(points[a], points[b], p) >= 0 && orient(points[b], points[c], p) >= 0 &&
                        orient(points[c], points[a], p) >= 0) {
                    blocked = true;
                    break;
                }
            }
            if (blocked) continue;
            output.insert(output.end(), { a, b, c });
            remaining.erase(remaining.begin() + i);
            found = true;
            break;
        }
        if (!found) return false;
    }
    if (orient(points[remaining[0]], points[remaining[1]], points[remaining[2]]) <= 0) return false;
    output.insert(output.end(), remaining.begin(), remaining.end());
    return true;
}

class SliceGeometry {
    std::array<double, 3> normal;
    double distance;
    double epsilon;
    std::vector<Vertex> vertices;
    std::unordered_map<EdgeKey, int> intersections;
    std::unordered_map<EdgeKey, int8_t> positive_seam;
    std::unordered_map<EdgeKey, int8_t> negative_seam;
    std::vector<std::vector<int>> loops;

    double signed_distance(const Vector3 &point) const {
        return normal[0] * point.x + normal[1] * point.y + normal[2] * point.z - distance;
    }

    int seam_vertex(Vertex &vertex) {
        if (vertex.seam < 0) {
            vertex.seam = int(seam_positions.size());
            seam_positions.emplace_back(real_t(vertex.position.x - normal[0] * vertex.distance),
                    real_t(vertex.position.y - normal[1] * vertex.distance),
                    real_t(vertex.position.z - normal[2] * vertex.distance));
        }
        return vertex.seam;
    }

    Corner edge_corner(const SurfaceInput &surface, int a, int b) {
        if (a > b) std::swap(a, b);
        const int va = surface.topology[a], vb = surface.topology[b];
        auto [entry, inserted] = intersections.try_emplace(edge_key(va, vb), int(seam_positions.size()));
        if (inserted) {
            // Always calculate the intersection in the same topological order,
            // independent of a face's direction or its render-vertex IDs.
            const Vertex &start = vertices[std::min(va, vb)];
            const Vertex &end = vertices[std::max(va, vb)];
            const double t = start.distance / (start.distance - end.distance);
            seam_positions.emplace_back(real_t(start.position.x + (double(end.position.x) - start.position.x) * t),
                    real_t(start.position.y + (double(end.position.y) - start.position.y) * t),
                    real_t(start.position.z + (double(end.position.z) - start.position.z) * t));
        }
        const double da = vertices[va].distance, db = vertices[vb].distance;
        return { a, b, entry->second, real_t(da / (da - db)) };
    }

    bool add_polygon(SurfaceSide &output, std::unordered_map<EdgeKey, int8_t> &seam,
            const std::array<Corner, 4> &polygon, int count, const Vector3 *source) const {
        std::array<int, 4> indices;
        for (int i = 0; i < count; ++i) {
            const int a = polygon[i].seam, b = polygon[(i + 1) % count].seam;
            if (a >= 0 && b >= 0 && !record_edge(seam, a, b)) return false;
            indices[i] = output.add_corner(polygon[i]);
        }
        for (int i = 1; i + 1 < count; ++i) {
            if (!has_area(position(polygon[0], source), position(polygon[i], source), position(polygon[i + 1], source))) return false;
            output.triangles.indices.insert(output.triangles.indices.end(), { indices[0], indices[i], indices[i + 1] });
        }
        return true;
    }

    bool collect_loops() {
        std::vector<int> outgoing(seam_positions.size(), -1);
        std::vector<bool> incoming(seam_positions.size(), false);
        size_t edge_count = 0;
        for (const auto &[key, direction] : positive_seam) {
            if (direction == 0) continue;
            const auto opposite = negative_seam.find(key);
            if (opposite == negative_seam.end() || opposite->second != -direction) return false;
            const int low = int(key >> 32), high = int(uint32_t(key));
            const int from = direction > 0 ? low : high, to = direction > 0 ? high : low;
            if (outgoing[from] >= 0 || incoming[to]) return false;
            outgoing[from] = to;
            incoming[to] = true;
            ++edge_count;
        }
        if (edge_count == 0 || edge_count != size_t(std::count_if(negative_seam.begin(), negative_seam.end(),
                [](const auto &edge) { return edge.second != 0; }))) return false;
        // Start at the lowest allocated seam index, independent of hash order.
        for (int start = 0; start < int(outgoing.size()); ++start) {
            if (outgoing[start] < 0) continue;
            std::vector<int> loop;
            int current = start;
            do {
                if (outgoing[current] < 0) return false;
                loop.push_back(current);
                const int next = outgoing[current];
                outgoing[current] = -1;
                current = next;
            } while (current != start);
            if (loop.size() < 3) return false;
            loops.push_back(std::move(loop));
        }
        return true;
    }

    bool build_caps() {
        const Vector3 axis = std::abs(cap_normal.x) < 0.8 ? Vector3(1, 0, 0) : Vector3(0, 1, 0);
        cap_tangent = axis.cross(cap_normal).normalized();
        const Vector3 bitangent = cap_normal.cross(cap_tangent).normalized();
        const Vector3 origin = seam_positions[loops.front().front()];
        cap_uv.reserve(seam_positions.size());
        for (const Vector3 &point : seam_positions) {
            const double x = double(point.x) - origin.x, y = double(point.y) - origin.y, z = double(point.z) - origin.z;
            cap_uv.push_back({ x * cap_tangent.x + y * cap_tangent.y + z * cap_tangent.z,
                    x * bitangent.x + y * bitangent.y + z * bitangent.z });
        }
        for (size_t li = 0; li < loops.size(); ++li) {
            const std::vector<int> &loop = loops[li];
            const size_t count = loop.size();
            double area = 0;
            for (size_t i = 0; i < count; ++i) {
                const Point2 &a = cap_uv[loop[i]], &b = cap_uv[loop[(i + 1) % count]];
                if (a.x == b.x && a.y == b.y) return false;
                const Point2 &next = cap_uv[loop[(i + 2) % count]];
                if (orient(a, b, next) == 0 && (between(next, a, b) || between(a, b, next))) return false;
                area += orient(cap_uv[loop.front()], a, b);
                for (size_t j = i + 2; j < count; ++j) {
                    if (i == 0 && j + 1 == count) continue;
                    if (segments_intersect(a, b, cap_uv[loop[j]], cap_uv[loop[(j + 1) % count]])) return false;
                }
            }
            // The exterior positive-side boundary is clockwise in this basis.
            // A reversed or nested contour cannot be capped as a solid disk.
            if (area >= 0) return false;
            for (size_t lj = 0; lj < li; ++lj) {
                const std::vector<int> &other = loops[lj];
                for (size_t i = 0; i < count; ++i) {
                    for (size_t j = 0; j < other.size(); ++j) {
                        if (segments_intersect(cap_uv[loop[i]], cap_uv[loop[(i + 1) % count]],
                                cap_uv[other[j]], cap_uv[other[(j + 1) % other.size()]])) return false;
                    }
                }
                if (contains_point(loop, cap_uv, cap_uv[other.front()]) || contains_point(other, cap_uv, cap_uv[loop.front()])) return false;
            }
            if (!triangulate(loop, cap_uv, cap_indices)) return false;
        }
        return true;
    }

public:
    Vector3 cap_normal;
    Vector3 cap_tangent;
    std::vector<SurfaceOutput> surfaces;
    std::vector<Vector3> seam_positions;
    std::vector<Point2> cap_uv;
    std::vector<int> cap_indices;

    SliceGeometry(const Plane &plane, double normal_length, double tolerance) :
            normal{ plane.normal.x / normal_length, plane.normal.y / normal_length, plane.normal.z / normal_length },
            distance(plane.d / normal_length), epsilon(tolerance), cap_normal(normal[0], normal[1], normal[2]) {}

    Vector3 position(const Corner &corner, const Vector3 *source) const {
        return corner.seam >= 0 ? seam_positions[corner.seam] : source[corner.a];
    }

    int loop_count() const { return int(loops.size()); }
    size_t welded_vertex_count() const { return vertices.size(); }

    const char *run(std::vector<SurfaceInput> &input) {
        size_t vertex_count = 0, element_count = 0;
        for (const SurfaceInput &surface : input) {
            vertex_count += size_t(surface.positions.size());
            element_count += size_t(surface.element_count());
        }
        if (vertex_count > size_t(std::numeric_limits<int>::max()) || element_count > size_t(std::numeric_limits<int>::max())) {
            return "The mesh is too large to slice.";
        }
        vertices.reserve(vertex_count);
        {
            std::unordered_map<Vector3, int, PositionHash> weld;
            weld.reserve(vertex_count);
            bool has_positive = false, has_negative = false;
            for (SurfaceInput &surface : input) {
                const Vector3 *source = surface.positions.ptr();
                surface.topology.resize(surface.positions.size());
                for (size_t i = 0; i < surface.topology.size(); ++i) {
                    const Vector3 &point = source[i];
                    if (!point.is_finite()) return "The mesh contains a non-finite vertex.";
                    auto [entry, inserted] = weld.try_emplace(point, int(vertices.size()));
                    surface.topology[i] = entry->second;
                    if (inserted) {
                        const double offset = signed_distance(point);
                        const int side = offset > epsilon ? 1 : (offset < -epsilon ? -1 : 0);
                        has_positive |= side > 0;
                        has_negative |= side < 0;
                        vertices.push_back({ point, offset, side });
                    }
                }
            }
            if (!has_positive || !has_negative) return "The plane does not cross the mesh.";
        }

        TopologyEdges topology_edges;
        if (!topology_edges.reserve(element_count / 2)) return "The mesh is too large to slice.";
        surfaces.reserve(input.size());
        for (const SurfaceInput &surface : input) {
            SurfaceOutput &output = surfaces.emplace_back(surface);
            const Vector3 *source = surface.positions.ptr();
            const int32_t *indices = surface.indices.is_empty() ? nullptr : surface.indices.ptr();
            const int count = int(surface.element_count());
            const int size = int(surface.topology.size());
            for (int face = 0; face < count; face += 3) {
                std::array<int, 3> ids, welded, sides;
                std::array<Corner, 4> corners;
                int positive = 0, negative = 0;
                for (int i = 0; i < 3; ++i) {
                    const int index = indices ? indices[face + i] : face + i;
                    if (index < 0 || index >= size) return "The mesh contains an invalid triangle index.";
                    ids[i] = index;
                    welded[i] = surface.topology[index];
                    Vertex &vertex = vertices[welded[i]];
                    sides[i] = vertex.side;
                    positive += vertex.side > 0;
                    negative += vertex.side < 0;
                    corners[i] = { index, -1, vertex.side == 0 ? seam_vertex(vertex) : -1 };
                }
                if (!has_area(source[ids[0]], source[ids[1]], source[ids[2]])) return "The mesh contains a degenerate triangle.";
                if (!topology_edges.record(welded[0], welded[1]) || !topology_edges.record(welded[1], welded[2]) ||
                        !topology_edges.record(welded[2], welded[0])) return "The mesh is not consistently oriented and edge-manifold.";
                if (positive == 0 && negative == 0) return "The plane overlaps a mesh face.";
                if (positive == 0 || negative == 0) {
                    SurfaceSide &side = positive ? output.positive : output.negative;
                    if (positive + negative == 3) {
                        // Already checked area and topology. Strictly retained
                        // triangles keep every original corner and have no seam.
                        for (int i = 0; i < 3; ++i) side.triangles.indices.push_back(side.add_corner(corners[i]));
                    } else if (!add_polygon(side, positive ? positive_seam : negative_seam, corners, 3, source)) {
                        return "The cut produces a degenerate side face or ambiguous edge.";
                    }
                    continue;
                }
                std::array<Corner, 4> upper, lower;
                int upper_count = 0, lower_count = 0;
                for (int i = 0; i < 3; ++i) {
                    const int next = (i + 1) % 3;
                    if (sides[i] >= 0) upper[upper_count++] = corners[i];
                    if (sides[i] <= 0) lower[lower_count++] = corners[i];
                    if (sides[i] * sides[next] < 0) {
                        const Corner intersection = edge_corner(surface, ids[i], ids[next]);
                        upper[upper_count++] = intersection;
                        lower[lower_count++] = intersection;
                    }
                }
                if (!add_polygon(output.positive, positive_seam, upper, upper_count, source) ||
                        !add_polygon(output.negative, negative_seam, lower, lower_count, source)) {
                    return "The cut produces a degenerate side face or ambiguous edge.";
                }
            }
        }
        if (!topology_edges.is_closed()) return "The mesh is open after exact position welding.";
        if (!collect_loops()) return "The plane does not produce matching closed cut boundaries.";
        if (!build_caps()) return "The cut contains a nested, touching, or degenerate contour.";
        return nullptr;
    }
};

template <class Packed>
void write_interpolated(const Packed &source, const SurfaceTriangles &side, Array &arrays, int channel) {
    if (source.is_empty()) return;
    Packed output;
    output.resize(side.vertices.size());
    const auto *values = source.ptr();
    auto *target = output.ptrw();
    for (size_t i = 0; i < side.vertices.size(); ++i) {
        const Corner &corner = side.vertices[i];
        target[i] = corner.b < 0 ? values[corner.a] : values[corner.a].lerp(values[corner.b], corner.fraction);
    }
    arrays[channel] = output;
}

Vector3 interpolated_normal(const Vector3 *normals, const Corner &corner) {
    if (corner.b < 0) return normals[corner.a];
    const Vector3 result = normals[corner.a].lerp(normals[corner.b], corner.fraction).normalized();
    return result == Vector3() ? normals[corner.fraction < 0.5 ? corner.a : corner.b].normalized() : result;
}

void write_normals_and_tangents(const SurfaceInput &source, const SurfaceTriangles &side, Array &arrays) {
    if (source.normals.is_empty()) return;
    PackedVector3Array normals;
    normals.resize(side.vertices.size());
    const Vector3 *source_normals = source.normals.ptr();
    Vector3 *normal_values = normals.ptrw();
    for (size_t i = 0; i < side.vertices.size(); ++i) {
        normal_values[i] = interpolated_normal(source_normals, side.vertices[i]);
    }
    arrays[Mesh::ARRAY_NORMAL] = normals;
    if (source.tangents.is_empty()) return;
    PackedFloat32Array tangents;
    tangents.resize(side.vertices.size() * 4);
    const float *input = source.tangents.ptr();
    float *target = tangents.ptrw();
    for (size_t i = 0; i < side.vertices.size(); ++i) {
        const Corner &corner = side.vertices[i];
        const float *first = input + 4 * corner.a;
        if (corner.b < 0) {
            std::copy_n(first, 4, target + 4 * i);
            continue;
        }
        const float *second = input + 4 * corner.b;
        Vector3 tangent = Vector3(first[0], first[1], first[2]).lerp(Vector3(second[0], second[1], second[2]), corner.fraction);
        tangent = tangent.slide(normal_values[i]).normalized();
        const float *nearest = corner.fraction < 0.5 ? first : second;
        if (tangent == Vector3()) tangent = Vector3(nearest[0], nearest[1], nearest[2]).slide(normal_values[i]).normalized();
        target[4 * i] = tangent.x;
        target[4 * i + 1] = tangent.y;
        target[4 * i + 2] = tangent.z;
        target[4 * i + 3] = nearest[3];
    }
    arrays[Mesh::ARRAY_TANGENT] = tangents;
}

bool append_surface(const Ref<ArrayMesh> &mesh, const Array &arrays, const Ref<Material> &material, const String &name) {
    const int index = mesh->get_surface_count();
    mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
    if (mesh->get_surface_count() != index + 1) return false;
    mesh->surface_set_material(index, material);
    mesh->surface_set_name(index, name);
    return true;
}

bool publish_side(const Ref<ArrayMesh> &mesh, const SurfaceInput &source, const SurfaceTriangles &side, const SliceGeometry &geometry) {
    if (side.indices.empty()) return true;
    Array arrays;
    arrays.resize(Mesh::ARRAY_MAX);
    PackedVector3Array positions;
    positions.resize(side.vertices.size());
    Vector3 *output = positions.ptrw();
    const Vector3 *original = source.positions.ptr();
    for (size_t i = 0; i < side.vertices.size(); ++i) output[i] = geometry.position(side.vertices[i], original);
    PackedInt32Array indices;
    indices.resize(side.indices.size());
    std::copy(side.indices.begin(), side.indices.end(), indices.ptrw());
    arrays[Mesh::ARRAY_VERTEX] = positions;
    arrays[Mesh::ARRAY_INDEX] = indices;
    write_normals_and_tangents(source, side, arrays);
    write_interpolated(source.colors, side, arrays, Mesh::ARRAY_COLOR);
    write_interpolated(source.uv, side, arrays, Mesh::ARRAY_TEX_UV);
    write_interpolated(source.uv2, side, arrays, Mesh::ARRAY_TEX_UV2);
    return append_surface(mesh, arrays, source.material, source.name);
}

bool publish_cap(const Ref<ArrayMesh> &mesh, const SliceGeometry &geometry, bool positive, const Ref<Material> &material,
        const std::vector<int> &cap_indices, std::vector<int> &mapping) {
    if (cap_indices.empty()) return true;
    Array arrays;
    arrays.resize(Mesh::ARRAY_MAX);
    PackedVector3Array positions, normals;
    PackedVector2Array uv;
    PackedFloat32Array tangents;
    PackedInt32Array indices;
    const Vector3 normal = positive ? -geometry.cap_normal : geometry.cap_normal;
    const Vector3 tangent = geometry.cap_tangent;
    const float handedness = positive ? -1.0f : 1.0f;
    indices.resize(cap_indices.size());
    int32_t *output = indices.ptrw();
    for (size_t i = 0; i < cap_indices.size(); ++i) {
        const int vertex = cap_indices[i];
        int &index = mapping[vertex];
        if (index < 0) {
            index = int(positions.size());
            positions.push_back(geometry.seam_positions[vertex]);
            normals.push_back(normal);
            const Point2 &p = geometry.cap_uv[vertex];
            uv.push_back(Vector2(p.x, p.y));
            tangents.push_back(tangent.x);
            tangents.push_back(tangent.y);
            tangents.push_back(tangent.z);
            tangents.push_back(handedness);
        }
        output[i] = index;
    }
    // The projected triangulation is CCW about +n. Godot treats clockwise
    // faces as front-facing, so it already faces outward on the positive half.
    if (!positive) {
        for (int64_t i = 0; i < indices.size(); i += 3) std::swap(output[i + 1], output[i + 2]);
    }
    arrays[Mesh::ARRAY_VERTEX] = positions;
    arrays[Mesh::ARRAY_NORMAL] = normals;
    arrays[Mesh::ARRAY_TANGENT] = tangents;
    arrays[Mesh::ARRAY_TEX_UV] = uv;
    arrays[Mesh::ARRAY_INDEX] = indices;
    return append_surface(mesh, arrays, material, "Slice Cap");
}

Dictionary failure(const char *message) {
    Dictionary result;
    result["error"] = String(message);
    return result;
}

class SliceComponents {
    std::vector<size_t> parents;
    std::vector<uint8_t> ranks;

public:
    explicit SliceComponents(size_t vertex_count) : parents(vertex_count), ranks(vertex_count) {
        std::iota(parents.begin(), parents.end(), size_t(0));
    }

    size_t root(size_t vertex) {
        while (parents[vertex] != vertex) {
            parents[vertex] = parents[parents[vertex]];
            vertex = parents[vertex];
        }
        return vertex;
    }

    void join_triangle(size_t a, size_t b, size_t c) {
        join(a, b);
        join(a, c);
    }

private:
    void join(size_t a, size_t b) {
        a = root(a);
        b = root(b);
        if (a == b) return;
        if (ranks[a] < ranks[b]) std::swap(a, b);
        parents[b] = a;
        if (ranks[a] == ranks[b]) ++ranks[a];
    }
};

bool publish_pieces(TypedArray<ArrayMesh> &output, const std::vector<SurfaceInput> &input, const SliceGeometry &geometry,
        bool positive, const Ref<Material> &cap_material) {
    constexpr size_t unassigned = std::numeric_limits<size_t>::max();
    const size_t welded_count = geometry.welded_vertex_count();
    const size_t vertex_count = welded_count + geometry.seam_positions.size();
    SliceComponents components(vertex_count);
    std::vector<std::vector<size_t>> piece_membership(input.size());
    for (size_t surface = 0; surface < input.size(); ++surface) {
        const SurfaceOutput &split = geometry.surfaces[surface];
        const SurfaceTriangles &triangles = (positive ? split.positive : split.negative).triangles;
        auto &vertices = piece_membership[surface];
        vertices.reserve(triangles.vertices.size());
        // Exterior attributes keep render seams, but connectivity must use the
        // same welded and on-plane vertex identities as the shell and cap.
        for (const Corner &corner : triangles.vertices) {
            vertices.push_back(corner.seam >= 0 ? welded_count + corner.seam : input[surface].topology[corner.a]);
        }
        for (size_t i = 0; i < triangles.indices.size(); i += 3) {
            components.join_triangle(vertices[triangles.indices[i]], vertices[triangles.indices[i + 1]], vertices[triangles.indices[i + 2]]);
        }
    }
    for (size_t i = 0; i < geometry.cap_indices.size(); i += 3) {
        components.join_triangle(welded_count + geometry.cap_indices[i], welded_count + geometry.cap_indices[i + 1],
                welded_count + geometry.cap_indices[i + 2]);
    }

    std::vector<size_t> piece_for_root(vertex_count, unassigned);
    std::vector<Ref<ArrayMesh>> pieces;
    for (auto &vertices : piece_membership) {
        for (size_t &vertex : vertices) {
            size_t &piece = piece_for_root[components.root(vertex)];
            if (piece == unassigned) {
                piece = pieces.size();
                pieces.emplace_back().instantiate();
            }
            vertex = piece;
        }
    }

    // This reusable lookup touches only groups present on a material surface.
    // It avoids an allocation per possible surface-and-piece combination.
    std::vector<size_t> group_for_piece(pieces.size(), unassigned);
    std::vector<int32_t> local_indices;
    for (size_t surface = 0; surface < input.size(); ++surface) {
        const SurfaceOutput &split = geometry.surfaces[surface];
        const SurfaceTriangles &triangles = (positive ? split.positive : split.negative).triangles;
        const auto &vertices = piece_membership[surface];
        if (vertices.empty()) continue;
        if (std::all_of(vertices.begin(), vertices.end(), [&](size_t piece) { return piece == vertices.front(); })) {
            if (!publish_side(pieces[vertices.front()], input[surface], triangles, geometry)) return false;
            continue;
        }

        struct SurfaceGroup {
            size_t piece;
            SurfaceTriangles triangles;
        };
        std::vector<SurfaceGroup> groups;
        local_indices.resize(vertices.size());
        for (size_t i = 0; i < vertices.size(); ++i) {
            const size_t piece = vertices[i];
            size_t &group = group_for_piece[piece];
            if (group == unassigned) {
                group = groups.size();
                groups.push_back({ piece, {} });
            }
            auto &corners = groups[group].triangles.vertices;
            local_indices[i] = int32_t(corners.size());
            corners.push_back(triangles.vertices[i]);
        }
        for (size_t i = 0; i < triangles.indices.size(); i += 3) {
            const int32_t a = triangles.indices[i], b = triangles.indices[i + 1], c = triangles.indices[i + 2];
            auto &indices = groups[group_for_piece[vertices[a]]].triangles.indices;
            indices.insert(indices.end(), { local_indices[a], local_indices[b], local_indices[c] });
        }
        for (const SurfaceGroup &group : groups) {
            if (!publish_side(pieces[group.piece], input[surface], group.triangles, geometry)) return false;
            group_for_piece[group.piece] = unassigned;
        }
    }

    std::vector<std::vector<int>> cap_by_piece(pieces.size());
    for (size_t i = 0; i < geometry.cap_indices.size(); i += 3) {
        const int a = geometry.cap_indices[i], b = geometry.cap_indices[i + 1], c = geometry.cap_indices[i + 2];
        const size_t piece = piece_for_root[components.root(welded_count + a)];
        if (piece == unassigned) return false;
        cap_by_piece[piece].insert(cap_by_piece[piece].end(), { a, b, c });
    }
    // A seam vertex belongs to exactly one piece on each side, so the cap
    // lookup can be shared across the disjoint caps of this half-space.
    std::vector<int> cap_mapping(geometry.seam_positions.size(), -1);
    for (size_t piece = 0; piece < pieces.size(); ++piece) {
        if (!publish_cap(pieces[piece], geometry, positive, cap_material, cap_by_piece[piece], cap_mapping)) return false;
        output.push_back(pieces[piece]);
    }
    return !output.is_empty();
}

double valid_plane_length(const Plane &plane, double epsilon) {
    if (!plane.is_finite() || !std::isfinite(epsilon) || epsilon < 0) return 0;
    const double length = std::hypot(double(plane.normal.x), double(plane.normal.y), double(plane.normal.z));
    return std::isfinite(length) ? length : 0;
}

constexpr char INVALID_PLANE[] = "A finite plane with a nonzero normal and a nonnegative epsilon is required.";
constexpr char INVALID_SURFACE[] = "The mesh contains unsupported or malformed rigid triangle surface arrays.";

Dictionary run_slice(std::vector<SurfaceInput> &input, const Plane &plane, double normal_length,
        const Ref<Material> &cap_material, double epsilon, bool separate) {
    SliceGeometry geometry(plane, normal_length, epsilon);
    if (const char *error = geometry.run(input)) return failure(error);

    Dictionary result;
    if (separate) {
        TypedArray<ArrayMesh> positive, negative;
        if (!publish_pieces(positive, input, geometry, true, cap_material) ||
                !publish_pieces(negative, input, geometry, false, cap_material)) {
            return failure("Could not create the connected sliced meshes.");
        }
        result["positive_pieces"] = positive;
        result["negative_pieces"] = negative;
    } else {
        Ref<ArrayMesh> positive, negative;
        positive.instantiate();
        negative.instantiate();
        for (size_t i = 0; i < input.size(); ++i) {
            if (!publish_side(positive, input[i], geometry.surfaces[i].positive.triangles, geometry) ||
                    !publish_side(negative, input[i], geometry.surfaces[i].negative.triangles, geometry)) {
                return failure("Could not create the sliced mesh surfaces.");
            }
        }
        std::vector<int> cap_mapping(geometry.seam_positions.size(), -1);
        if (!publish_cap(positive, geometry, true, cap_material, geometry.cap_indices, cap_mapping)) {
            return failure("Could not create the slice caps.");
        }
        std::fill(cap_mapping.begin(), cap_mapping.end(), -1);
        if (!publish_cap(negative, geometry, false, cap_material, geometry.cap_indices, cap_mapping)) {
            return failure("Could not create the slice caps.");
        }
        result["positive_mesh"] = positive;
        result["negative_mesh"] = negative;
    }
    result["loop_count"] = geometry.loop_count();
    return result;
}

Dictionary slice_rigid(const Ref<ArrayMesh> &mesh, const Plane &plane, const Ref<Material> &cap_material, double epsilon, bool separate) {
    if (mesh.is_null() || mesh->get_surface_count() == 0) return failure("A nonempty ArrayMesh is required.");
    if (mesh->get_blend_shape_count() != 0) return failure("The rigid slicer does not accept blend shapes.");
    const double normal_length = valid_plane_length(plane, epsilon);
    if (normal_length == 0) return failure(INVALID_PLANE);
    const int count = mesh->get_surface_count();
    std::vector<SurfaceInput> input(count);
    for (int surface = 0; surface < count; ++surface) {
        if (mesh->surface_get_primitive_type(surface) != Mesh::PRIMITIVE_TRIANGLES ||
                !input[surface].read(mesh->surface_get_arrays(surface), mesh->surface_get_material(surface), mesh->surface_get_name(surface))) {
            return failure(INVALID_SURFACE);
        }
    }
    return run_slice(input, plane, normal_length, cap_material, epsilon, separate);
}

}

void MeshPlaneSlice::_bind_methods() {
    ClassDB::bind_static_method("MeshPlaneSlice", D_METHOD("slice_mesh", "mesh", "plane", "cap_material", "epsilon"),
            &MeshPlaneSlice::slice_mesh, DEFVAL(Ref<Material>()), DEFVAL(0.000001));
    ClassDB::bind_static_method("MeshPlaneSlice", D_METHOD("slice_mesh_pieces", "mesh", "plane", "cap_material", "epsilon"),
            &MeshPlaneSlice::slice_mesh_pieces, DEFVAL(Ref<Material>()), DEFVAL(0.000001));
    ClassDB::bind_static_method("MeshPlaneSlice", D_METHOD("slice_pose", "mesh", "skeleton", "plane", "cap_material", "epsilon"),
            &MeshPlaneSlice::slice_pose, DEFVAL(Ref<Material>()), DEFVAL(0.000001));
}

Dictionary MeshPlaneSlice::slice_mesh(const Ref<ArrayMesh> &mesh, const Plane &plane, const Ref<Material> &cap_material, double epsilon) {
    return slice_rigid(mesh, plane, cap_material, epsilon, false);
}

Dictionary MeshPlaneSlice::slice_mesh_pieces(const Ref<ArrayMesh> &mesh, const Plane &plane, const Ref<Material> &cap_material, double epsilon) {
    return slice_rigid(mesh, plane, cap_material, epsilon, true);
}

Dictionary MeshPlaneSlice::slice_pose(MeshInstance3D *mesh, Skeleton3D *skeleton, const Plane &plane,
        const Ref<Material> &cap_material, double epsilon) {
    const double normal_length = valid_plane_length(plane, epsilon);
    if (normal_length == 0) return failure(INVALID_PLANE);
    std::vector<SurfaceInput> input;
    {
        std::vector<MeshPoseSurface> posed;
        if (!MeshPartition::snapshot_pose_surfaces(mesh, skeleton, posed)) return failure("The posed mesh could not be captured.");
        input.resize(posed.size());
        for (size_t surface = 0; surface < posed.size(); ++surface) {
            if (!input[surface].read(posed[surface].arrays, posed[surface].material, posed[surface].name)) return failure(INVALID_SURFACE);
        }
    }
    return run_slice(input, plane, normal_length, cap_material, epsilon, true);
}

}
