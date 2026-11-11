extends Node3D

@onready var _emitters: Array[CPUParticles3D] = [$HotCore, $Flame, $Sparks]

func fire() -> void:
	show()
	for emitter in _emitters:
		emitter.restart()

func clear() -> void:
	hide()
	for emitter in _emitters:
		emitter.emitting = false
