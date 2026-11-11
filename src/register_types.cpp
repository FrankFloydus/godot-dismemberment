#include "register_types.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

#include "limb_map.h"
#include "mesh_partition.h"
#include "mesh_plane_slice.h"
#include "dismembered_limb.h"
#include "dismemberment_component.h"
#include "blood_pool.h"
#include "gore_component.h"


using namespace godot;

void initialize_gdextension_types(ModuleInitializationLevel p_level)
{
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	GDREGISTER_CLASS(LimbMap);
	GDREGISTER_CLASS(MeshPartition);
	GDREGISTER_CLASS(MeshPlaneSlice);
	GDREGISTER_CLASS(DismemberedAnimInstance);
	GDREGISTER_CLASS(DismemberedLimb);
	GDREGISTER_CLASS(DismembermentComponent);
	GDREGISTER_CLASS(BloodPool);
	GDREGISTER_CLASS(GoreComponent);
}

void uninitialize_gdextension_types(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
}

extern "C"
{
	// Initialization
	GDExtensionBool GDE_EXPORT godot_dismemberment_library_init(GDExtensionInterfaceGetProcAddress p_get_proc_address, GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization)
	{
		GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
		init_obj.register_initializer(initialize_gdextension_types);
		init_obj.register_terminator(uninitialize_gdextension_types);
		init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

		return init_obj.init();
	}
}
