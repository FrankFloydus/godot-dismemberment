@tool
extends MultiMesh

func _reset_state() -> void:
	# The editor reapplies the saved format when it reloads a cached resource.
	instance_count = 0
