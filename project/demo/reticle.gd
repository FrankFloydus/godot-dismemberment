extends Control

const HIT_DURATION := 0.22
const AXES := [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]
const CORNERS := [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]
const CONTRAST := Color(0.016, 0.039, 0.05, 0.95)

## Color of the idle aiming marks.
@export var aim_color := Color(0.74, 1, 0.97)
## Color of the marker for a hit on a severable bone.
@export var cut_hit_color := Color(1, 0.47, 0.28)
## Color of the marker for a hit on a protected bone.
@export var protected_hit_color := Color(1, 0.81, 0.43)

var hit_time := 0.0
var valid_hit := true

func _ready() -> void:
	resized.connect(queue_redraw)
	set_process(false)
	queue_redraw()

func register_hit(valid: bool) -> void:
	valid_hit = valid
	hit_time = HIT_DURATION
	set_process(true)
	queue_redraw()

func _process(delta: float) -> void:
	hit_time = maxf(0.0, hit_time - delta)
	if hit_time == 0.0:
		set_process(false)
	queue_redraw()

func _draw() -> void:
	var center := size * 0.5
	for axis in AXES:
		var start: Vector2 = center + axis * 7.0
		var end: Vector2 = center + axis * 15.0
		draw_line(start, end, CONTRAST, 4.0, true)
		draw_line(start, end, aim_color, 1.5, true)
	draw_circle(center, 2.6, CONTRAST, true, -1.0, true)
	draw_circle(center, 1.15, aim_color, true, -1.0, true)

	if hit_time > 0.0:
		var strength := hit_time / HIT_DURATION
		var spacing := lerpf(9.0, 6.5, strength)
		var hit_color := cut_hit_color if valid_hit else protected_hit_color
		hit_color.a *= sqrt(strength)
		for direction in CORNERS:
			var start: Vector2 = center + direction * spacing
			var end: Vector2 = start + direction * 5.0
			draw_line(start, end, CONTRAST * Color(1, 1, 1, hit_color.a), 3.5, true)
			draw_line(start, end, hit_color, 1.7, true)
