extends Node2D
# 길건너 친구들 스타일 프로토타입 (Kenney 타일 사용)
# 조작: 방향키 / WASD, 또는 화면 탭(앞으로)·스와이프(방향)

const T := 64.0               # 타일 크기 (16px x 4배)
const HALF_COLS := 4          # 플레이 가능 칸: -4..4 (9칸)
const WRAP := 11.0 * T        # 차/통나무가 되돌아가는 가장자리
const AHEAD := 16
const BEHIND := 8
const IDLE_LIMIT := 9.0

const TILE_GRASS := 44
const TILE_ROAD := 63
const TILE_WATER := 35
const TILE_TREE_TOP := 68
const TILE_TREE_BOT := 80
const TILE_BUSH := 71
const TILE_ROCK := 118
const TILE_PLAYER := 120
const CAR_TILES := [[122, 123], [124, 125]]

enum Kind { GRASS, ROAD, RIVER }

var lanes: Dictionary = {}    # row -> Dictionary
var player: Node2D
var sprite: Sprite2D
var cam: Camera2D
var world: Node2D
var row := 0
var col := 0
var best_row := 0
var hopping := false
var alive := true
var idle := 0.0
var river_streak := 0
var rng := RandomNumberGenerator.new()
var hi := 0
var touch_start := Vector2.ZERO

var score_label: Label
var hi_label: Label
var over_box: Control
var over_title: Label
var over_sub: Label
var tex_cache: Dictionary = {}


func tex(i: int) -> Texture2D:
	if not tex_cache.has(i):
		tex_cache[i] = load("res://Tiles/tile_%04d.png" % i)
	return tex_cache[i]


func make_sprite(i: int, pos: Vector2) -> Sprite2D:
	var s := Sprite2D.new()
	s.texture = tex(i)
	s.scale = Vector2(4, 4)
	s.position = pos
	return s


func _ready() -> void:
	rng.randomize()
	_load_hi()
	world = Node2D.new()
	add_child(world)
	cam = Camera2D.new()
	add_child(cam)
	_build_hud()
	_new_game()


func _new_game() -> void:
	for c in world.get_children():
		c.queue_free()
	lanes.clear()
	row = 0
	col = 0
	best_row = 0
	idle = 0.0
	hopping = false
	alive = true
	river_streak = 0
	over_box.visible = false
	for r in range(-BEHIND, AHEAD):
		_make_lane(r)
	player = Node2D.new()
	player.z_index = 50
	player.position = Vector2(0, 0)
	world.add_child(player)
	var shadow := ColorRect.new()
	shadow.color = Color(0, 0, 0, 0.25)
	shadow.size = Vector2(36, 12)
	shadow.position = Vector2(-18, 14)
	player.add_child(shadow)
	sprite = make_sprite(TILE_PLAYER, Vector2.ZERO)
	player.add_child(sprite)
	cam.position = Vector2(0, -3 * T)
	_update_score()


# ---------------------------------------------------------------- 길 만들기
func _make_lane(r: int) -> void:
	var kind: Kind = Kind.GRASS
	if r > 1:
		var roll := rng.randf()
		if roll < 0.30:
			kind = Kind.GRASS
		elif roll < 0.72:
			kind = Kind.ROAD
		else:
			kind = Kind.RIVER
		if kind == Kind.RIVER and river_streak >= 2:
			kind = Kind.GRASS
	river_streak = river_streak + 1 if kind == Kind.RIVER else 0

	var node := Node2D.new()
	node.position = Vector2(0, -r * T)
	world.add_child(node)
	var data := {"kind": kind, "node": node, "movers": [], "blocked": {}, "dir": 1, "speed": 0.0}
	lanes[r] = data

	var bg := TextureRect.new()
	bg.stretch_mode = TextureRect.STRETCH_TILE
	bg.size = Vector2(23 * 16, 16)
	bg.scale = Vector2(4, 4)
	bg.position = Vector2(-11.5 * T, -T / 2)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	match kind:
		Kind.GRASS:
			bg.texture = tex(TILE_GRASS)
			bg.modulate = Color(0.85, 1.35, 0.65) if r % 2 == 0 else Color(0.78, 1.25, 0.6)
		Kind.ROAD:
			bg.texture = tex(TILE_ROAD)
		Kind.RIVER:
			bg.texture = tex(TILE_WATER)
			bg.modulate = Color(0.35, 0.65, 1.6)
	node.add_child(bg)

	match kind:
		Kind.GRASS:
			_fill_grass(r, data)
		Kind.ROAD:
			_fill_road(data)
		Kind.RIVER:
			_fill_river(data)


func _fill_grass(r: int, data: Dictionary) -> void:
	var node: Node2D = data["node"]
	var blocked: Dictionary = data["blocked"]
	for c in range(-10, 11):
		var edge := absi(c) > HALF_COLS
		var place := edge or (r > 0 and rng.randf() < 0.17 and c != 0)
		if r <= 0 and not edge:
			place = false
		if not place:
			continue
		blocked[c] = true
		var roll := rng.randf()
		var p := Vector2(c * T, 0)
		if roll < 0.7 or edge:
			var top := make_sprite(TILE_TREE_TOP, p + Vector2(0, -T))
			top.z_index = 20
			node.add_child(top)
			node.add_child(make_sprite(TILE_TREE_BOT, p))
		elif roll < 0.88:
			node.add_child(make_sprite(TILE_BUSH, p))
		else:
			node.add_child(make_sprite(TILE_ROCK, p))
	# 최소 한 칸은 지나갈 수 있게
	if blocked.size() > 0:
		var free := 0
		for c in range(-HALF_COLS, HALF_COLS + 1):
			if not blocked.has(c):
				free += 1
		if free == 0:
			blocked.erase(0)


func _fill_road(data: Dictionary) -> void:
	var node: Node2D = data["node"]
	var dir := 1 if rng.randf() < 0.5 else -1
	var speed := rng.randf_range(90.0, 230.0)
	data["dir"] = dir
	data["speed"] = speed
	var count := rng.randi_range(3, 5)
	var span := WRAP * 2.0
	var gap := span / count
	var off := rng.randf() * gap
	for i in count:
		var car := Node2D.new()
		car.z_index = 10
		var pair: Array = CAR_TILES[rng.randi() % CAR_TILES.size()]
		var a: int = pair[0]
		var b: int = pair[1]
		var left := make_sprite(a, Vector2(-T / 2, 0))
		var right := make_sprite(b, Vector2(T / 2, 0))
		if dir > 0:
			left.texture = tex(b)
			right.texture = tex(a)
			left.flip_h = true
			right.flip_h = true
		car.add_child(left)
		car.add_child(right)
		car.position = Vector2(-WRAP + off + i * gap, 0)
		node.add_child(car)
		data["movers"].append({"node": car, "half": T})


func _fill_river(data: Dictionary) -> void:
	var node: Node2D = data["node"]
	var dir := 1 if rng.randf() < 0.5 else -1
	var speed := rng.randf_range(50.0, 120.0)
	data["dir"] = dir
	data["speed"] = speed
	var count := rng.randi_range(3, 4)
	var span := WRAP * 2.0
	var gap := span / count
	var off := rng.randf() * gap
	for i in count:
		var tiles := rng.randi_range(2, 3)
		var w := tiles * T
		var lg := Node2D.new()
		lg.z_index = 5
		var edge := ColorRect.new()
		edge.color = Color(0.28, 0.16, 0.12)
		edge.size = Vector2(w, T - 10)
		edge.position = Vector2(-w / 2, -(T - 10) / 2)
		lg.add_child(edge)
		var body := ColorRect.new()
		body.color = Color(0.62, 0.40, 0.24)
		body.size = Vector2(w - 8, T - 18)
		body.position = Vector2(-w / 2 + 4, -(T - 18) / 2)
		lg.add_child(body)
		var ring := ColorRect.new()
		ring.color = Color(0.78, 0.56, 0.36)
		ring.size = Vector2(6, T - 26)
		ring.position = Vector2(-w / 2 + 12, -(T - 26) / 2)
		lg.add_child(ring)
		lg.position = Vector2(-WRAP + off + i * gap, 0)
		node.add_child(lg)
		data["movers"].append({"node": lg, "half": w / 2})


# ---------------------------------------------------------------- 매 프레임
func _process(delta: float) -> void:
	for r in lanes:
		var d: Dictionary = lanes[r]
		if d["kind"] == Kind.GRASS:
			continue
		for m in d["movers"]:
			var n: Node2D = m["node"]
			n.position.x += d["dir"] * d["speed"] * delta
			if n.position.x > WRAP:
				n.position.x -= WRAP * 2.0
			elif n.position.x < -WRAP:
				n.position.x += WRAP * 2.0

	if alive:
		_check_player(delta)
	var target := Vector2(0, player.position.y - 3 * T)
	cam.position = cam.position.lerp(target, 1.0 - exp(-6.0 * delta))
	_manage_lanes()


func _check_player(delta: float) -> void:
	var d: Dictionary = lanes.get(row, {})
	if d.is_empty():
		return
	var px := player.position.x
	if d["kind"] == Kind.ROAD:
		for m in d["movers"]:
			var n: Node2D = m["node"]
			if absf(n.position.x - px) < float(m["half"]) + 14.0:
				_die("차에 부딪혔어요!", "squash")
				return
	elif d["kind"] == Kind.RIVER and not hopping:
		var on_log := false
		for m in d["movers"]:
			var n: Node2D = m["node"]
			if absf(n.position.x - px) < float(m["half"]) - 6.0:
				on_log = true
				break
		if on_log:
			player.position.x += d["dir"] * d["speed"] * delta
			if absf(player.position.x) > (HALF_COLS + 1.2) * T:
				_die("물살에 휩쓸렸어요!", "drown")
		else:
			_die("물에 빠졌어요!", "drown")
			return
	idle += delta
	if idle > IDLE_LIMIT:
		_die("꾸물대다 독수리에게 잡혔어요!", "squash")


func _manage_lanes() -> void:
	var top := row + AHEAD
	var last: int = lanes.keys().max()
	while last < top:
		last += 1
		_make_lane(last)
	for r in lanes.keys():
		if r < row - BEHIND:
			lanes[r]["node"].queue_free()
			lanes.erase(r)


# ---------------------------------------------------------------- 입력
func _unhandled_input(event: InputEvent) -> void:
	if not alive:
		if (event is InputEventKey and event.pressed and not event.echo) \
				or (event is InputEventMouseButton and event.pressed):
			if over_box.visible and over_box.get_meta("ready", false):
				_new_game()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_UP, KEY_W, KEY_SPACE:
				_hop(0, 1)
			KEY_DOWN, KEY_S:
				_hop(0, -1)
			KEY_LEFT, KEY_A:
				_hop(-1, 0)
			KEY_RIGHT, KEY_D:
				_hop(1, 0)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			touch_start = event.position
		else:
			var v: Vector2 = event.position - touch_start
			if v.length() < 24:
				_hop(0, 1)
			elif absf(v.x) > absf(v.y):
				_hop(int(signf(v.x)), 0)
			else:
				_hop(0, 1 if v.y < 0 else -1)


func _hop(dx: int, dr: int) -> void:
	if hopping or not alive:
		return
	var cur_col := roundi(player.position.x / T)
	var new_col := cur_col + dx
	var new_row := row + dr
	if absi(new_col) > HALF_COLS:
		return
	if new_row < best_row - 4 and dr < 0:
		return
	var tl: Dictionary = lanes.get(new_row, {})
	if tl.is_empty() or tl["blocked"].has(new_col):
		return
	hopping = true
	row = new_row
	if dr > 0 and row > best_row:
		best_row = row
		idle = 0.0
		_update_score()
	if dx != 0:
		sprite.flip_h = dx < 0
	var target := Vector2(new_col * T, -new_row * T)
	var tw := create_tween()
	tw.tween_property(player, "position", target, 0.11)
	var hop := create_tween()
	hop.tween_property(sprite, "position:y", -22.0, 0.055).set_ease(Tween.EASE_OUT)
	hop.tween_property(sprite, "position:y", 0.0, 0.055).set_ease(Tween.EASE_IN)
	tw.finished.connect(func() -> void: hopping = false)
	_squash_stretch()


func _squash_stretch() -> void:
	var t := create_tween()
	t.tween_property(sprite, "scale", Vector2(3.6, 4.5), 0.05)
	t.tween_property(sprite, "scale", Vector2(4, 4), 0.06)


func _die(msg: String, style: String) -> void:
	if not alive:
		return
	alive = false
	var t := create_tween()
	if style == "squash":
		t.tween_property(sprite, "scale", Vector2(5.2, 0.7), 0.12)
		t.parallel().tween_property(sprite, "position:y", 22.0, 0.12)
	else:
		t.tween_property(sprite, "scale", Vector2(2.0, 2.0), 0.4)
		t.parallel().tween_property(sprite, "modulate:a", 0.0, 0.4)
	if best_row > hi:
		hi = best_row
		_save_hi()
	_update_score()
	over_title.text = msg
	over_sub.text = "점수 %d  ·  최고 %d\n\n아무 키나 화면을 눌러 다시 시작" % [best_row, hi]
	over_box.visible = true
	over_box.set_meta("ready", false)
	get_tree().create_timer(0.5).timeout.connect(func() -> void: over_box.set_meta("ready", true))


# ---------------------------------------------------------------- 화면 표시
func _make_label(size: int, color: Color) -> Label:
	var l := Label.new()
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["Pretendard", "Malgun Gothic", "Apple SD Gothic Neo", "Noto Sans CJK KR", "Noto Sans KR", "NanumGothic"])
	l.add_theme_font_override("font", f)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0.1, 0.07, 0.1))
	l.add_theme_constant_override("outline_size", size / 5)
	return l


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	score_label = _make_label(56, Color.WHITE)
	score_label.position = Vector2(20, 8)
	layer.add_child(score_label)
	hi_label = _make_label(22, Color(1, 0.9, 0.5))
	hi_label.position = Vector2(24, 72)
	layer.add_child(hi_label)

	over_box = Control.new()
	over_box.set_anchors_preset(Control.PRESET_FULL_RECT)
	over_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(over_box)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.45)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	over_box.add_child(dim)
	over_title = _make_label(40, Color(1, 0.55, 0.45))
	over_title.set_anchors_preset(Control.PRESET_FULL_RECT)
	over_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	over_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	over_title.offset_top = -60
	over_box.add_child(over_title)
	over_sub = _make_label(24, Color.WHITE)
	over_sub.set_anchors_preset(Control.PRESET_FULL_RECT)
	over_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	over_sub.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	over_sub.offset_top = 150
	over_box.add_child(over_sub)
	over_box.visible = false


func _update_score() -> void:
	score_label.text = str(best_row)
	hi_label.text = "최고 %d" % maxi(hi, best_row)


func _load_hi() -> void:
	var f := FileAccess.open("user://hi.txt", FileAccess.READ)
	if f:
		hi = int(f.get_as_text())


func _save_hi() -> void:
	var f := FileAccess.open("user://hi.txt", FileAccess.WRITE)
	if f:
		f.store_string(str(hi))
