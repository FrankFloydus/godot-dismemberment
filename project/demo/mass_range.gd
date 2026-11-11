extends "res://demo/demo.gd"
## A first-person range for running the same attacks against 30 authored targets.

signal mass_action_finished(result: Dictionary)

const MassSlice := preload("res://demo/fps_mass_slice.gd")
const MassDismember := preload("res://demo/fps_mass_dismember.gd")

@export_group("Mass Murder")
## Outward speed applied to each severed limb, in metres per second.
@export_range(0.0, 20.0, 0.1, "suffix:m/s") var mass_blast_speed := 6.5
## Upward speed applied to each severed limb, in metres per second.
@export_range(0.0, 8.0, 0.1, "suffix:m/s") var mass_blast_lift := 2.4

var mass_slice := MassSlice.new()
var mass_dismember := MassDismember.new()
var mass_action_active := false
var last_mass_action: Dictionary = {}
var _resetting := false
var _closing := false


func _ready() -> void:
	super._ready()
	mass_slice.completed.connect(_on_mass_slice_completed)
	player.global_position = $OverviewSpawn.global_position
	_look_at($OverviewAim.global_position)
	player.reset_physics_interpolation()
	_clear_weapon_motion()
	station_label.text = "OVERVIEW"
	_feedback("ALL TARGETS READY")


func _update_stats() -> void:
	if not mass_dismember.running:
		super._update_stats()


func _process(delta: float) -> void:
	if mass_action_active:
		feedback_time = maxf(feedback_time, 1.0)
	super._process(delta)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed and (testing or Input.mouse_mode == Input.MOUSE_MODE_CAPTURED):
				_begin_mass_action(&"dismember")
			return
		if mass_action_active and event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE]:
			return
	elif event is InputEventKey and event.pressed and not event.echo:
		var key: int = event.physical_keycode if event.physical_keycode != 0 else event.keycode
		match key:
			KEY_R:
				_reset_range()
				return
			KEY_F:
				_begin_mass_action(&"slice")
				return
			KEY_B:
				if not mass_action_active:
					last_shot = _shoot(true)
				return
			KEY_C:
				if not mass_action_active:
					super._unhandled_input(event)
					_feedback("DETACHED BODIES CLEARED · R resets the range")
				return
			KEY_X, KEY_V:
				if mass_action_active:
					return
	super._unhandled_input(event)


func _begin_mass_action(action: StringName) -> void:
	if mass_action_active:
		return
	_cancel_slash()
	mass_action_active = true
	if action == &"slice":
		_feedback("PREPARING MASS SLICE · %d TARGETS" % targets.size())
		if not mass_slice.start(self, plane_slicing, targets):
			_finish_mass_action(action, {"targets": 0, "cuts": 0})
	else:
		fire_shake_time = fire_shake_duration
		_feedback("PREPARING MASS MURDER · %d TARGETS" % targets.size())
		_run_mass_dismember.call_deferred()


func _run_mass_dismember() -> void:
	if _closing or _resetting:
		return
	var result: Dictionary = await mass_dismember.run(self, targets, mass_blast_speed, mass_blast_lift)
	if not _resetting and int(result.get("cuts", 0)) > 0:
		range_audio.play_body_impact($OverviewAim.global_position, true)
	_finish_mass_action(&"dismember", result)


func _on_mass_slice_completed(result: Dictionary) -> void:
	if not _resetting:
		total_cuts += int(result.get("cuts", 0))
		if int(result.get("targets", 0)) > 0:
			range_audio.play_body_impact($OverviewAim.global_position, true)
	_finish_mass_action(&"slice", result)


func _finish_mass_action(action: StringName, result: Dictionary) -> void:
	if _closing or _resetting:
		return
	mass_action_active = false
	last_mass_action = result.duplicate()
	last_mass_action["action"] = action
	var affected := int(result.get("targets", 0))
	match action:
		&"slice":
			_feedback("MASS SLICE · %d TARGETS · %d PIECES" % [affected, result.get("fragments", 0)], affected == 0)
		&"dismember":
			_feedback("MASS MURDER · %d TARGETS · %d SEVERS" % [affected, result.get("cuts", 0)], affected == 0)
		&"reset":
			_feedback("RANGE RESET · %d TARGETS RESTORED" % affected)
	mass_action_finished.emit(last_mass_action)


func _reset_range() -> void:
	if _resetting:
		return
	_resetting = true
	mass_action_active = true
	_cancel_slash()
	_feedback("RESETTING THE RANGE")
	mass_slice.cancel()
	mass_dismember.cancel()
	while mass_slice.is_running() or mass_dismember.running:
		await get_tree().process_frame
	for index in targets.size():
		_reset_target(index, false)
		await get_tree().process_frame
	_sync_hitboxes()
	_resetting = false
	_finish_mass_action(&"reset", {"targets": targets.size()})


func _should_ragdoll_on_sever(bone: StringName) -> bool:
	return not mass_dismember.running and super._should_ragdoll_on_sever(bone)


func _report_skeletal_sever(bone: StringName, title: String) -> void:
	if not mass_action_active:
		super._report_skeletal_sever(bone, title)


func _exit_tree() -> void:
	_closing = true
	mass_slice.cancel()
	mass_dismember.cancel()
	super._exit_tree()
