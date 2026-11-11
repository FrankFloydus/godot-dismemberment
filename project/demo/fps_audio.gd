extends Node

const LOCAL_CLIPS := "user://range_audio"
const BODY_VOICE_COUNT := 8

## Horizontal ground distance between footfalls, in metres.
@export_range(0.2, 4.0, 0.05, "suffix:m") var step_spacing := 1.55
## Variations for a hit on an attached or already detached body part.
@export var flesh_hits: AudioStreamRandomizer
## Variations for a successful dismemberment.
@export var sever_sounds: AudioStreamRandomizer

@onready var _shot: AudioStreamPlayer = $Shotgun
@onready var _step: AudioStreamPlayer = $Footsteps
@onready var _room: AudioStreamPlayer = $RoomTone
@onready var _body_voice: AudioStreamPlayer3D = $BodyVoice

var _distance_to_step := 0.0
var _body_voices: Array[AudioStreamPlayer3D] = []
var _next_body_voice := 0

func _ready() -> void:
	reset_footsteps()
	if DirAccess.dir_exists_absolute(LOCAL_CLIPS):
		_apply_local_clips(_shot.stream as AudioStreamRandomizer, "shotgun")
		_apply_local_clips(_step.stream as AudioStreamRandomizer, "step")
		_apply_local_clips(flesh_hits, "flesh_hit")
		_apply_local_clips(sever_sounds, "sever")
	_body_voices.append(_body_voice)
	for index in range(1, BODY_VOICE_COUNT):
		var voice := _body_voice.duplicate() as AudioStreamPlayer3D
		add_child(voice)
		_body_voices.append(voice)
	if DisplayServer.get_name() != "headless":
		_room.play()

func _exit_tree() -> void:
	_room.stop()
	_step.stop()
	_shot.stop()
	for voice in _body_voices:
		voice.stop()

func play_shot() -> void:
	_shot.play()

func play_body_impact(contact: Vector3, severed := false) -> void:
	var samples := sever_sounds if severed else flesh_hits
	if samples == null:
		return
	var voice := _body_voices[_next_body_voice]
	_next_body_voice = (_next_body_voice + 1) % _body_voices.size()
	voice.stop()
	voice.stream = samples
	voice.global_position = contact
	voice.reset_physics_interpolation()
	voice.play()

func advance_steps(travel: Vector3, grounded: bool) -> void:
	if not grounded:
		reset_footsteps()
		return
	_distance_to_step -= Vector2(travel.x, travel.z).length()
	if _distance_to_step <= 0.0:
		_step.play()
		_distance_to_step += step_spacing

func reset_footsteps() -> void:
	_distance_to_step = step_spacing * 0.6

func _apply_local_clips(variations: AudioStreamRandomizer, prefix: String) -> void:
	if variations == null:
		return
	for index in variations.streams_count:
		var path := LOCAL_CLIPS.path_join("%s_%02d.wav" % [prefix, index + 1])
		if FileAccess.file_exists(path):
			var clip := AudioStreamWAV.load_from_file(path)
			if clip != null:
				variations.set_stream(index, clip)
