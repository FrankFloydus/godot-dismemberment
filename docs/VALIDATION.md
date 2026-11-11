# Validation record

Date: 11 November 2026. Engine: Godot 4.7.stable.official.5b4e0cb0f,
Windows x86_64, standard precision, RTX 4090. The cut comparison below uses
OpenGL Compatibility. The current demo and rendered suite use Vulkan Forward+.
The native bindings target the Godot 4.3 API. The demo uses GodotPhysics3D
at 240 physics ticks per second and 32 solver iterations. Other engine
versions and distribution platforms were not executed.

Both Windows native targets were compiled with SCons 4.8.1 and MSVC C++17:

    ./tools/build.ps1

## Experimental plane slicing

`test_mesh_plane_slice.gd` checks closed mesh geometry, cap winding and
material, signed volume, disjoint and concave sections, recuts, and safe
rejection. `test_fps_plane_slicing.gd` drives the actual demo keys and camera
rays through an oblique forearm cut, a fragment recut, and reset.

The Windows release DLL was measured in Vulkan Forward+ on the FPS humanoid
with 262,348 triangles. Three fresh processes per version each performed
three cuts with R resets, VSync disabled and cut cues muted. The optimized
kernel uses a contiguous edge table for oriented topology validation and
copies triangles that lie strictly on one side without clipping them.

| Measurement | Initial median | Optimized median |
| --- | ---: | ---: |
| First cut, handler return | 182.4 ms | 95.7 ms |
| First cut, next draw signal | 184.6 ms | 98.1 ms |
| Later cut, handler return | 162.4 ms | 89.8 ms |
| Slice geometry and surface creation | 128.2 ms | 53.3 ms |

Pose capture took about 23 ms. The forearm quick cut rebuilds the full posed
mesh synchronously and holds the remainder in the captured pose until reset.

### Whole-mesh swipes

The geometry suite checks separate connected pieces, material and cap
preservation, volume conservation, and direct pose capture. The demo test
uses actual middle-mouse gestures and camera rays. A horizontal waist swipe
produces three contours and four independently simulated pieces. A second
swipe recuts the upper piece, and a diagonal swipe puts the caps on its
sloped plane. The test also checks reach, short gestures, and reset.

On the same 262,348-triangle character in Windows release Forward+, a
waist swipe took a median **219 ms** to the next draw across three fresh
processes. Recutting the upper piece took a median **67 ms** in the input
handler. Direct posed slicing took **86 ms** in paired geometry calls,
compared with **100 ms** when the snapshot was first published as an
intermediate render mesh. Geometry and convex collision are still built
synchronously in the demo.

### Frame time after multiple swipes

Three waist cuts produced 12 rigid fragments at the range's usual 240 Hz
physics rate. The Windows release test used a fixed 1440 × 900 Forward+
viewport with VSync disabled. Each condition sampled 100 frames after
1.35 seconds of falling and floor contact. The order was full hulls,
bounded hulls, bounded hulls, full hulls.

| Measurement | Full convex hulls | Bounded convex hulls |
| --- | ---: | ---: |
| Points per fragment in this test | 806–2,036 | 59–80 |
| Median physics tick | 5.27 ms | 0.91 ms |
| Median frame time | 39.5 ms | 1.18 ms |
| 95th-percentile frame time | 41.1 ms | 1.80 ms |

Both modes submitted the same visible and shadow primitive counts. The
bounded collider is an approximation of the full convex hull and keeps its
body-axis extents. These measurements cover simulation after the cuts. The
input-to-cut timings are recorded above.

### Reloading and mixed cuts

The saved editor tab order opens the FPS scene before the separate range
scene. Godot 4.7 emitted 12 transform-format errors on that reload before
the fix. The range's MultiMeshes now clear their instance allocation during
resource reset, and the same editor startup and authored scene regression
complete without those errors.

The native geometry tests cover cap holes, islands inside holes, nested
separate shells, recutting an annular cap, and rejecting touching contours.
On the posed demo model, horizontal cuts at local heights of 0.62 m and
0.84 m produce six and nine contours respectively. The lower cut also
passes through the actual mouse gesture in the FPS test.

The demo regressions fire real pellets at a rigid slice fragment and the
retained quick-cut torso. They also sever an arm and swipe the remaining
body while checking that the detached arm is preserved. A separate Forward+
check swipes a moving source ragdoll after a head cut.

The localized sever test cuts individual branches from an already sliced
mesh and checks the closed edges, cap winding, preserved branch, and signed
volumes. In the FPS demo, shots sever an arm and then a leg from the same
quick-cut body. A regular eight-pellet shell also severs the selected arm
from a moved and rotated waist-slice fragment. The test checks the detached
bounds and verifies that the other fragments remain. Blood-only shots
keep the limb attached.

A follow-up shell targets a sibling fragment after the original rigid body
has been freed. Before the fix Godot reported a null body when resolving its
old collision exception. The regression now checks that both shots sever and
every surviving fragment lists only live collision peers.

### Mass range

The viewport integration test uses the authored 30-station scene and sends
real RMB, F, and R input events. It samples visibility during preparation,
checks that the physics world stays active, and verifies the staged limb
layers, the one-frame release, and the reset of both types of cut. The
20-target fixture removes ten instances at runtime after verifying the
saved scene. The unique-geometry fixture builds 30 independent source mesh
resources and checks each detached limb against its own source mesh RID.

On Godot 4.7 Forward+ at 1600 × 900 with VSync disabled, a paired Windows
debug run on Ryzen 9 7900X and RTX 4090 released the same 73 limbs from 30
targets. The shared fixture took 247 ms from RMB to release and had a 47 ms
worst frame gap. The independent mesh fixture took 251 ms with a 51 ms
worst gap. Release itself took 20 ms and 19 ms respectively. Independent
meshes added 349 MiB of render-buffer memory before and after the action.
The 20-target Windows release run with the original mesh launched 50 limbs
after 217 ms, with 15 ms spent in release and a 53 ms worst frame gap.

The full-detail F benchmark used the same target poses and cut choices before
and after moving pose baking, surface assembly, and hull sampling to workers.
Retaining CPU cap arrays also avoids reading those surfaces back from the
renderer to apply the cut stain and place the interior. With the renderer
settled, the full-detail Debug run went from 4.167 s to 1.647 s. Both runs
produced 36 planes and 136 pieces and the optimized run published in 6.85 ms.

A second same-seed rendered Debug comparison used the optimized build with
the original body and the 19,990-triangle mass range body. Both cut all 30
targets using 42 planes and produced 146 fragments in one visible frame.
The original body took 1.536 s. The mass range body took 0.581 s and
spent 11.86 ms publishing. The 95th-percentile and worst frame gaps were
26 and 53 ms for that mass range run. A warm rerun with the same 9 ms
preparation budget took 0.392 s, with a 22 ms 95th-percentile gap and a 27 ms
worst gap. Cutting the moving ragdolls after RMB affected all 30 in both
fixtures and took 0.939 s with the mass range body and 2.776 s with the
original body.

#### Four consecutive mass slices

The same-seed Forward+ comparison used the 19,990-triangle crowd body,
1600 × 900 with VSync disabled, and the Windows release DLL. It measured
frame gaps for roughly half a second immediately after each of four F
presses. The first three presses cut all 30 targets. The fourth cut 25,
with the other five already at or near the 12-fragment limit. Both builds
ended with 326 live fragments. Every fragment retained its collision shape
and remained eligible for further hits and cuts within the existing limits.

| GodotPhysics3D configuration | After F3, frame p95 | After F4, frame p95 |
| --- | ---: | ---: |
| 60 Hz, 16 solver iterations, before | 17.4 ms | 20.7 ms |
| 60 Hz, 16 solver iterations, after | 7.5 ms | 9.3 ms |
| 240 Hz, 32 solver iterations, before | 43.2 ms | 52.3 ms |
| 240 Hz, 32 solver iterations, after | 35.5 ms | 41.6 ms |

At 60 Hz after F4, active broad-phase pairs fell from 3,855 to 1,460 by
removing the replaced rigs' colliders. Draw calls fell from 4,043 to 2,726
by merging the default interior faces that share a material on each
fragment. Arbitrary custom materials keep their per-volume transforms.
The engine settings were matched within each pair and are controlled by
the host project during normal use.

The repeated and mixed-action suites also passed with Jolt at 60 Hz. They
verified that all 1,170 original collider RIDs leave the physics world on
the first F and are restored on R. Jolt reported warnings for unsupported
parameters on the existing authored joints, with zero test errors.

## FPS cut latency

Measured the authored FPS scene on the same Godot 4.7 Compatibility renderer
and Windows x86_64 release DLL configuration described above. The probe used
the regular left-click handler and real camera rays, with gore enabled. It
alternated baseline and optimized DLLs in six fresh game processes per
version, rotating the first cut among LeftArm, Head, and LeftLeg. Each process
took five more shots with R resets in between. The measurements are wall
times from the click handler entry and use a fixed 120 FPS simulation clock
with VSync disabled.

| Measurement | Baseline median | Optimized median |
| --- | ---: | ---: |
| First cut, click handler return | 111.21 ms | 9.17 ms |
| First cut, native post-dismemberment signal | 185.20 ms | 72.71 ms |
| First cut, next draw signal | 191.98 ms | 79.45 ms |
| Later cuts, next draw signal | 179.08 ms | 68.04 ms |

Standalone mesh partition on the same character took 99.24 ms median across
18 calls. Bone Collapse now skips partitioning when authored articulation
succeeds or rigid fallback is disabled. An additional paired run isolated the
paint changes. The first-cut deferred interval fell from 77.74 ms to 65.19 ms
median. Skin detection reads ArrayMesh format flags, and painting accesses
packed arrays once per surface. Mesh reconstruction and renderer upload
remain part of paint. With all gore effects disabled, the partition-only
change brought the first cut to the next draw from 111.45 ms to 10.47 ms
median across three fresh processes per version.

The local harness is work/cut-perf/bench.gd. Direct comparison logs are
work/cut-perf-final-baseline-*.log and work/cut-perf-final-optimized-*.log.
Separate comparisons are in work/cut-perf-paired-*.log and
work/cut-perf-paint-*.log.

The full Forward+ shotgun demo was also exercised with the pre-optimization
and final release DLLs. Each variant used three fresh processes and six shots
per process in the same scene.

| Forward+ measurement | Baseline median | Final median |
| --- | ---: | ---: |
| First click, handler return | 189.20 ms | 36.42 ms |
| First click, next draw signal | 310.07 ms | 115.49 ms |
| Later clicks, next draw signal | 283.37 ms | 81.97 ms |

Scratch instrumentation located the remaining first-handler difference inside
the native cut call. The sound, viewmodel, ray, and tracer work before that
call took under 0.4 ms in the instrumented first shot.

The native integration suite checks that the rigid fallback hull excludes the
source core while the detached skin retains its topology. Both DLLs passed the
rendered 35-check FPS shooting and R-reset test with scripted input isolated
from desktop events. The baseline and optimized release DLLs both passed all
20 joint-integrity checks in the paired stress run, with the same full-cut
right wrist anchor gap of 0.00706 m.

## Forward+ range and shot feedback

The authored demo runs with SDFGI, volumetric fog, glow, and AgX tone mapping.
Fresh import covers the CC0 bullpup and embedded metal and polymer textures.
The updated authored demo check includes positional audio on the exact cut
contact and the moved detached-arm contact. It checks that one shell uses one
body voice for a severed subject.

The shotgun regression exercises 50 headless checks and 56 rendered checks.
It compares the eight mark transforms to ray contacts, tests the floor response,
checks the bounded impact pool, and verifies one hit and seven misses from a
mixed shell. The rendered pass compares tracer origins with the barrel after
recoil and verifies that each trail keeps its own fixed endpoint.
It also checks that the three one-shot muzzle emitters have 3D meshes, finish
their bursts, and clear when the player switches stations. Forward+ frame
captures show the flash from the firing station and the back of the range.

Rendered captures at 16, 42, 100, and 183 ms cover near, oblique, and far
metal impacts and the dust-dominant floor. An independent ray check confirms
11 contacts on the visible ceiling, walls, panels, and bay geometry. An off-tree
decal prepared at startup removed the first-use decal instantiation from the
shot. The isolated first environment shot measured about 0.6–0.8 ms in the
handler after that change.

The local audio mix was checked through the Godot audio bus. The recorded
room tone measured approximately −43 dBFS RMS. Reverb kept the first 18 ms of
the close Remington take at the same level. The wet-only tail measured about
−42 dBFS RMS at 380–520 ms and −60 dBFS RMS at 630–740 ms. The package includes
the CC0 recordings and a clean project can run without the optional local WAVs.

A separate mixer probe aimed and fired at the authored arm with a fixed local
take. The body peak rose from −15.9 to −6.6 dBFS at the station. Sidechain
compression reduced the shotgun layer by about 4 dB RMS during the cut. The
combined peak was −3.7 dBFS. The far cut remained spatial, with a body peak of
−13.4 dBFS and a combined peak of −6.8 dBFS in the probe.

## Inspector property descriptions

The editor build embeds XML member descriptions for all 60 native properties
declared by the addon. All 15 FPS scene settings carry GDScript documentation
comments. The headless runner passed on both Windows builds, including the
172-check component Inspector suite and the 37-check authored FPS suite. See
work/property-tooltips-debug.log and work/property-tooltips-release.log.

## Component Inspector and icon

Both Windows DLLs passed the 172-check component Inspector regression, including
conditional property visibility, inherited rules, refresh signals, and scene
round-tripping of hidden values. The rendered FPS camera-ray and R-reset
regression passed on both builds. An isolated Godot 4.7 editor probe checked
43 live Inspector groups and controls and verified that the Scene tree and
Inspector resolve the native GoreComponent SVG icon. See the logs under work,
including gore-inspector-editor-verify.log and component-inspector-validated
logs for both DLLs.

## Editable FPS scene

The main scene saves the range, player, HUD, all three skinned targets, and
their native components, ragdoll bodies, and hitboxes as editable nodes. Both
Windows x86_64 DLLs passed the 37-check authored-scene regression. It inspects
the saved scene before play and verifies that a real camera ray passes edited
impulse values to the native cut. It also checks an inherited station's edited
spawn marker. Both builds passed the rendered runner, including the 35-check
camera-ray and R-reset suite and the rendered ragdoll comparison. Evidence
is in work/authored-demo-validated-debug.log and
work/authored-demo-validated-release.log.

## Rename validation

The addon, GDExtension descriptor, runtime manifest, entry symbol, and Windows
DLLs now use the godot-dismemberment name. The renamed Windows x86_64 debug
and release builds passed native integration, mesh partition, two-process
ENet, blood effects, and attachment socket checks on Godot 4.7. Both DLLs
also passed the full rendered suite, including 35 FPS camera-ray and R-reset
checks, and the separate 35-check physics reset suite. See
work/rename-rendered-debug.log, work/rename-rendered-release.log, and
work/rename-reset-debug.log and work/rename-reset-release.log.

The full-ragdoll floor-impact test measured a maximum right wrist anchor gap
of 0.10602 m in both renamed builds. The unchanged 0.08 m limit flagged one of
20 assertions. A fresh extraction of the pre-rename demo archive reproduced
the same 0.10602 m gap. The historical validation below records the earlier
runs. The current logs are work/rename-validation-debug.log,
work/rename-validation-release.log, and work/rename-baseline-joints.log.

## Final complete runner

The extended headless and actual OpenGL runner passed against both native
libraries with zero engine errors or warnings. Release validation changed
only the descriptor in an isolated project so the debug-feature engine loaded
the actual template_release DLL. The existing user editor was not used as the
test harness or closed.

| Suite | Checks per DLL | Result |
| --- | ---: | --- |
| Native integration | 108 | Passed |
| Procedural mesh partition | 169 | Passed |
| Two-process ENet (server 9, client 17) | 26 | Passed |
| Gore source audit | 21 | Passed |
| Removed source physics / explicit simulator ownership | 15 | Passed |
| Authored physics, momentum and real-rig contact | 46 | Passed |
| Joint integrity against component-free control | 20 | Passed |
| Five reset cycles on translated/rotated actor | 35 | Passed |
| Rendered articulated attachment transfer | 16 | Passed |
| Rendered procedural body cuts | 34 | Passed |
| Rendered actual CC0 model geometry | 29 | Passed |
| Rendered sequential cuts and same-frame reset/cut | 8 | Passed |
| Actual FPS camera-ray shots and R-key resets | 35 | Passed |
| Rendered detached head follows physical body | 8 | Passed |
| Original animations, ragdoll controls, reset and sequential cuts | 26 | Passed |
| **Total per native build** | **596** | **Passed, exit 0** |

The headless physics test explicitly skips two renderer assertions; the
separate eight-check OpenGL head test executes those with zero skips.
Headless integration likewise reports its live attachment-motion skip;
the rendered 16-check attachment test includes the motion assertions.
Dummy headless skin results are not accepted as proof of rendered skin.

Coverage includes named/indexed Skin binds, four/eight influences, shared
resource isolation, bone filters/remaps, nested cuts, destroy/reset/cleanup,
current pose and blend shapes, materials, attachments, authority/owner
requests, late join, duplicate suppression, and mass-independent velocity.
The geometry suite checks transforms, custom channels, LOD remapping,
materials, vertex attributes, bounds and source immutability.

## Diagnosis of the reported stretching

The original CC0 run/walk clips and component-free authored ragdoll remain
bounded. The weights are valid. Original and normalized posed geometry match
within 0.000073 m after the constant origin adjustment. The large strips
were plugin faults involving renderer-pose capture, already missing bones
in subsequent cuts, and restoration of source joints.

R reset rebuilt joints while parents still occupied fallen poses.
Restored node transforms concealed the inconsistent solver frames.
The reset now stops simulation, disables joints, restores every body into
one coherent pose, and then rebuilds authored constraints. Simulation
owners restore body modes and callbacks; reset does not replay a raw
captured rigid mode. The clean renderer palette is published before reset
returns, including a new cut in the same frame.

| Targeted measurement | Before fix | After fix |
| --- | ---: | ---: |
| Worst solver joint gap across five reset cycles | 3.945 m | 0.048697 m |
| Maximum source-body diagonal in those cycles | about 4.12 m | 1.888509 m |
| Third-cycle Head/neck anchor separation, rendered comparison | about 1.55 m | 0.000123 m |
| Third-cycle source maximum triangle edge | 0.521 m | 0.069536 m |
| Final sequential Head/arm/leg source maximum edge | long strips reproduced | 0.068472 m |

The final FPS test shoots Head, LeftLeg, Head and LeftArm through real camera
rays, using R on the same target between shots. It checks source and detached
triangle edges below 0.2 m, restored rendered vertices within 0.001 m, and a
protected-core shot. The final debug and release runs measured maximum source
edge 0.074343 m, detached edge 0.045476 m and reset vertex error below
0.000000361 m.
REAL_MODEL_GEOMETRY_AUDIT.md explains the controls and earlier failures.

The 17-body demo totals 75 kg. The selected rig fits the hand boxes and body
offsets to weighted hand geometry in each Hand bone's rest frame. Hand contact
friction is 0.35, with original 6DOF joint limits and unchanged body masses.
In the complete 240 Hz / 32 iteration runs, the full ragdoll's final-second
mean speed was about 0.000322 m/s; the three-body arm settled to approximately
0.00015-0.00017 m/s. The full ragdoll peaked at 73.24 rad/s and spent 0.0167 s
above 50 rad/s. No artificial velocity clamp was added.

The final complete runs measured worst five-cycle joint gaps of 0.059159 m
(debug) and 0.027544 m (release), with zero restored-body pose and solver/node
errors. Two additional release joint runs passed all 20 checks each. An
independent release reset repeat passed all 35 checks with 0.055714 m maximum
gap. The initial final-rig reset trial passed at 0.078810 m, below the unchanged
0.08 m limit. The acceptance limit is a test criterion, not a guarantee for
every possible impact, platform, rig or timestep.

Earlier stress runs with the old hand colliders exposed an authoritative
0.1444 m wrist gap; even a component-free 480 Hz control exceeded the limit.
Faster steps, wrist hinges, stiffer linear locks, fitted boxes alone and
higher-quality Jolt were evaluated and rejected when any strict suite failed.
This separates contact authoring/solver sensitivity from the earlier native
reset defect. The plugin preserves authored physics and stays backend neutral.

## Editor and export checks

The editor plugin registers a runtime-manifest autoload with explicit native,
shader and texture dependencies. Isolated checks exercised selected-scene
PCK export, resource inclusion, a second genuine extension, and an occupied
autoload name through enable/disable cycles. A Windows debug export verified
the native DLL sidecar using the installed editor executable as a custom
template. Matching standard Godot 4.7 export templates were not installed;
an official release-template executable was not tested.

## Experimental slicing burst on 20 humanoids

On November 11, 2026, a Godot 4.7 Forward+ run with the Windows x86-64
release DLL used the real demo rig on a Ryzen 9 7900X and RTX 4090 at
1600 × 900 with VSync disabled. The test supplied registered contacts
directly to the existing slash and pellet-hit paths so every cut could
occur before the next physics step. Each of 20 targets was sliced,
shot to sever an arm, and subjected to a radial blast. The 148 checks
verified 100 launched rigid fragments, 40 torso halves with interior
geometry and stain, 20 severed arms with their existing forearm
interior, and complete fragment cleanup after reset.

| Metric | Before authored interiors and early hull reduction | Integrated |
| --- | ---: | ---: |
| Burst CPU time | 4.83 s | 3.64 s |
| Time to the next process frame | 4.85 s | 3.69 s |
| Median torso slash | 175.47 ms | 147.53 ms |
| Median shotgun sever | 60.82 ms | 28.17 ms |
| Average FPS over the first 0.75 s after the burst | 195.5 | 106.5 |
| Average FPS in the later 0.75 s window | 174.2 | 126.8 |

Sampling directional support points before convex-hull construction
shortened the burst CPU time by 24.6% in this comparison. The added
geometry and exterior stain passes increased measured draw calls from
851 to 1,751 in the first window after the burst. Cutting every subject
in one frame still causes a multi-second hitch on this setup.
The staged benchmark on the same hardware passed 210 checks. It
captured standing poses and published render meshes and colliders on the
main thread across frames, and computed each geometry split on a worker.
In the staged run all 20 slashes published together in 4.21 ms of CPU
time. After the shotgun stage, all 100 fragments received their radial
impulses together in 0.47 ms, with 10.4 ms until the next process frame.
The corresponding synchronous run took 4.41 s until its next frame.
The staged run took 5.05 s from request to blast and recorded 123 ms
p95 and 321 ms maximum frame gaps during preparation. Off-tree body
creation was the largest main-thread step. The same run recorded a
497 ms frame gap before the request.

The invocation is in [the demo guide](DEMO_README.md).

## Reproduce and evidence

    # Standard headless suites:
    ./tools/run_tests.ps1 -Godot 'C:/path/to/Godot_console.exe'
    # Full validation, including rendered skin, FPS input and R reset:
    ./tools/run_tests.ps1 -Godot 'C:/path/to/Godot_console.exe' -Extended -Rendered
    # Isolated project while the main editor remains open:
    ./tools/run_tests.ps1 -ProjectPath 'C:/path/to/copy' -Extended -Rendered

Each suite requires its success marker and zero exit; added behavior suites
also reject engine-error output. Rebuild DLLs after C++ edits. Restart an open
Godot editor to load a changed native DLL: reloadable=false deliberately avoids
replacing live native code.

Final aggregate logs: work/validation-final-debug.log and
work/validation-final-release.log. Build log: work/build-final.log.
Additional targeted logs: work/godot240_run1.log through godot240_run3.log,
godot240_reset.log, jolt120_momentum.log, fitted_hand_friction_release_*.log, and
work/ragdoll-comparison-reset-fix/comparison.json.
Scratch evidence, original Unreal source/assets, caches and temporary DLL
copies are excluded from ZIPs. The packaging tool checks CRCs and records
archive SHA-256 hashes in dist/manifest.json.

## Equivalence boundary

These checks establish recorded behavior on the tested rigs and engine.
They do not establish pixel identity, identical Niagara behavior, identical
solver results, or exact Unreal editor workflow equivalence. The default
source-like bone-collapse method retains skin topology; it does not generate
new anatomical interior geometry or polygonal cut caps. PARITY.md and
GORE_MAPPING.md identify remaining adaptations and comparison work.
