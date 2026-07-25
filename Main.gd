extends Node3D
##
## Godot 推箱子 (Sokoban) 游戏
## =============================
## 从 Blender (bpy) 版本移植而来。
## 程序化构建 3D 场景 + 推箱子逻辑。
## 关卡从 res://levels/*.txt 动态加载。
##
## 操作：WASD/方向键 移动 | X 旋转箱子 | Z 回退 | V 切换玩家 | R 旋转视角 | ESC 返回
##

# ============================================================
# 常量
# ============================================================
const CELL_SIZE: float = 1.0
const SELECT_SCENE := "res://LevelSelect.tscn"
const PLAYER_COLORS := [
	Color(0.15, 0.45, 0.85),
	Color(0.85, 0.20, 0.20),
	Color(0.20, 0.80, 0.30),
	Color(0.85, 0.75, 0.15),
	Color(0.60, 0.25, 0.75),
	Color(0.15, 0.70, 0.70),
	Color(0.90, 0.50, 0.10),
	Color(0.55, 0.35, 0.70),
]

# ============================================================
# 关卡数据
# ============================================================
var GRID_COLS: int = 8
var GRID_ROWS: int = 8
var LEVEL_GRID: Array = []
var BOX_POSITIONS: Array = []
var PLAYER_STARTS: Array = []
var LEVEL_NAME: String = ""
var LEVEL_PATH: String = ""

# ============================================================
# 材质
# ============================================================
var mat_target: StandardMaterial3D
var mat_win_target: StandardMaterial3D
var mat_box: StandardMaterial3D
var _player_mats: Array = []

# ============================================================
# 场景对象
# ============================================================
var _player_objs: Array = []
var _cursor_obj: Node3D
var _box_objs := {}
var _target_objs := {}
var _bridge_nodes: Array = []
var _hud_label: Label

# ============================================================
# 游戏状态
# ============================================================
var _players: Array = []        # [{col, row, facing}]
var _active_player: int = 0
var boxes: Array = []
var _occ: Dictionary = {}
var targets := {}
var move_count: int = 0
var won: bool = false

var _last_move_time: float = 0.0
var _undo_stack: Array = []

# 摄像机
var _cam: Camera3D
var _cam_angle: float = 0.0
var _tp_pos: Vector3
var _tp_look: Vector3


func _ready() -> void:
	if not _load_selected_level():
		return
	_collect_targets()
	_build_scene()
	reset_game()
	print("=".repeat(50))
	print("  推箱子游戏开始! 关卡: %s" % LEVEL_NAME)
	print("  WASD/方向键 = 移动 | X Z V R ESC | 人数: %d" % _players.size())
	print("=".repeat(50))


# ============================================================
# 关卡加载
# ============================================================
func _load_selected_level() -> bool:
	var path := LevelLoader.selected_level_path
	# 未经选关界面直接运行本场景时，回退到第一关
	if path == "":
		var all := LevelLoader.list_levels()
		if all.is_empty():
			push_error("未找到任何关卡文件 (res://levels/*.txt)")
			return false
		path = all[0]

	var data := LevelLoader.load_level(path)
	if not data.ok:
		push_error("关卡加载失败: %s" % data.error)
		return false

	LEVEL_PATH = path
	LEVEL_NAME = data.name
	LEVEL_GRID = data.grid
	GRID_COLS = data.cols
	GRID_ROWS = data.rows
	BOX_POSITIONS = data.boxes
	PLAYER_STARTS = data.player_starts
	return true


# ============================================================
# 坐标转换：网格 → 世界。row=0 在远处, row 增大朝摄像机方向。
# Godot 为 Y-up，用 X/Z 平面作为地面。
# ============================================================
func grid_to_world(col: int, row: int, y: float = 0.0) -> Vector3:
	var x := (col - GRID_COLS / 2.0 + 0.5) * CELL_SIZE
	var z := (row - GRID_ROWS / 2.0 + 0.5) * CELL_SIZE
	return Vector3(x, y, z)


func _collect_targets() -> void:
	targets.clear()
	for row in range(GRID_ROWS):
		for col in range(GRID_COLS):
			if LEVEL_GRID[row][col] == 2:
				targets[Vector2i(col, row)] = true


# ============================================================
# 玩家状态快捷访问
# ============================================================
func _ap() -> Dictionary:
	return _players[_active_player] if _players.size() > _active_player else {"col": 0, "row": 0, "facing": Vector2i(0, 1)}


# ============================================================
# 材质工具
# ============================================================
func make_material(base_color: Color, roughness := 0.5, metallic := 0.0,
		emit_color: Color = Color(0, 0, 0), emit_strength := 0.0) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = base_color
	mat.roughness = roughness
	mat.metallic = metallic
	if emit_strength > 0.0:
		mat.emission_enabled = true
		mat.emission = emit_color
		mat.emission_energy_multiplier = emit_strength
	return mat


## 噪声纹理材质 (三向贴图，适合无 UV 的 BoxMesh)。
func _noise_mat(base: Color, freq: float, rough: float) -> StandardMaterial3D:
	var noise := FastNoiseLite.new()
	noise.seed = randi()
	noise.frequency = freq
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	var tex := NoiseTexture2D.new()
	tex.noise = noise
	tex.width = 128
	tex.height = 128
	tex.seamless = true
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.albedo_color = base
	mat.roughness = rough
	mat.uv1_triplanar = true
	return mat


func _add_mesh(mesh: Mesh, mat: Material, pos: Vector3, name := "") -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	if name != "":
		mi.name = name
	add_child(mi)
	return mi


# ============================================================
# 场景构建
# ============================================================
func _build_scene() -> void:
	print(">>> 构建推箱子游戏场景...")

	# --- 材质 ---
	var mat_floor := make_material(Color(0.25, 0.25, 0.30), 0.9)
	var mat_wall := _noise_mat(Color(0.58, 0.55, 0.50), 0.03, 0.75)
	mat_target = make_material(Color(0.15, 0.15, 0.15), 0.8, 0.0,
		Color(0.1, 0.9, 0.3), 1.5)
	mat_box = _noise_mat(Color(0.72, 0.48, 0.30), 0.08, 0.50)
	mat_win_target = make_material(Color(0.1, 0.1, 0.1), 0.8, 0.0,
		Color(0.05, 0.95, 0.2), 3.0)
	var mat_indicator := make_material(Color(0.9, 0.9, 0.9), 0.2)

	# --- 地板 ---
	var floor_size: float = max(GRID_COLS, GRID_ROWS) * CELL_SIZE * 1.6
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(floor_size, floor_size)
	_add_mesh(floor_mesh, mat_floor, Vector3(0, -0.01, 0), "游戏地板")

	# --- 墙壁 & 目标 ---
	_target_objs.clear()
	for row in range(GRID_ROWS):
		for col in range(GRID_COLS):
			var cell = LEVEL_GRID[row][col]
			var pos := grid_to_world(col, row, 0.0)

			if cell == 1:  # 墙
				var wall_mesh := BoxMesh.new()
				wall_mesh.size = Vector3.ONE * (CELL_SIZE * 0.95)
				_add_mesh(wall_mesh, mat_wall, pos + Vector3(0, 0.5, 0),
					"墙_%d_%d" % [col, row])

			elif cell == 2:  # 目标点
				var t_mesh := PlaneMesh.new()
				t_mesh.size = Vector2(CELL_SIZE * 0.7, CELL_SIZE * 0.7)
				var t := _add_mesh(t_mesh, mat_target, pos + Vector3(0, 0.005, 0),
					"目标_%d_%d" % [col, row])
				_target_objs[Vector2i(col, row)] = t

	# --- 箱子 (0.92 留缝隙，多格由桥接长方体填平) ---
	_box_objs.clear()
	for b in BOX_POSITIONS:
		for bp in b:
			var pos := grid_to_world(bp.x, bp.y, CELL_SIZE / 2.0)
			var box_mesh := BoxMesh.new()
			box_mesh.size = Vector3.ONE * (CELL_SIZE * 0.92)
			var box := _add_mesh(box_mesh, mat_box, pos, "箱子_%d_%d" % [bp.x, bp.y])
			_box_objs[bp] = box

	# --- 玩家 (不同颜色) ---
	_player_objs.clear()
	for pi in PLAYER_STARTS.size():
		var ppos := grid_to_world(PLAYER_STARTS[pi].x, PLAYER_STARTS[pi].y, CELL_SIZE / 2.0)
		var mat_p := make_material(PLAYER_COLORS[pi % PLAYER_COLORS.size()], 0.3, 0.3)
		_player_mats.append(mat_p)
		var cyl := CylinderMesh.new()
		cyl.top_radius = CELL_SIZE * 0.3
		cyl.bottom_radius = CELL_SIZE * 0.3
		cyl.height = CELL_SIZE * 0.8
		cyl.radial_segments = 16
		var pobj := _add_mesh(cyl, mat_p, ppos, "玩家%d" % pi)
		# 方向指示球
		var sph := SphereMesh.new()
		sph.radius = CELL_SIZE * 0.10
		sph.height = CELL_SIZE * 0.20
		var indicator := MeshInstance3D.new()
		indicator.mesh = sph
		indicator.material_override = mat_indicator
		indicator.position = Vector3(0, CELL_SIZE * 0.45, CELL_SIZE * -0.15)
		indicator.name = "方向指示"
		pobj.add_child(indicator)
		_player_objs.append(pobj)

	# --- 光标 (切换玩家指示) ---
	var cursor_mesh := PlaneMesh.new()
	cursor_mesh.size = Vector2(CELL_SIZE * 0.5, CELL_SIZE * 0.5)
	_cursor_obj = Node3D.new()
	var cursor_mi := MeshInstance3D.new()
	cursor_mi.mesh = cursor_mesh
	cursor_mi.material_override = mat_indicator
	cursor_mi.position = Vector3(0, 0.02, 0)
	_cursor_obj.add_child(cursor_mi)
	_cursor_obj.name = "玩家光标"
	add_child(_cursor_obj)

	# --- 灯光 ---
	var sun := DirectionalLight3D.new()
	sun.name = "太阳光"
	sun.light_energy = 1.5
	sun.rotation_degrees = Vector3(-55, -30, 0)
	sun.position = Vector3(5, 12, -5)
	sun.shadow_enabled = true
	add_child(sun)

	var point := OmniLight3D.new()
	point.name = "补光"
	point.position = Vector3(-3, 5, 2)
	point.light_energy = 2.0
	point.omni_range = 15.0
	point.light_color = Color(1.0, 0.95, 0.85)
	add_child(point)

	# --- 环境（天空/环境光）---
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.08, 0.08, 0.1)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.4, 0.4, 0.45)
	e.ambient_light_energy = 0.6
	env.environment = e
	add_child(env)

	# --- 摄像机 ---
	var span: float = max(GRID_COLS, GRID_ROWS)
	_tp_pos = Vector3(0, span * 1.15, span * 1.15)
	_tp_look = Vector3(0, 0, 0.5)
	_cam = Camera3D.new()
	_cam.name = "游戏摄像机"
	_cam.fov = 70
	_cam.current = true
	add_child(_cam)

	# --- HUD ---
	var canvas := CanvasLayer.new()
	add_child(canvas)
	_hud_label = Label.new()
	_hud_label.add_theme_font_size_override("font_size", 22)
	_hud_label.add_theme_color_override("font_color", Color.WHITE)
	_hud_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_hud_label.add_theme_constant_override("outline_size", 4)
	_hud_label.position = Vector2(20, 16)
	canvas.add_child(_hud_label)

	var total_cells := 0
	for b in BOX_POSITIONS:
		total_cells += b.size()
	print("  场景构建完成: %dx%d 网格, %d 个箱子(%d 格), %d 个目标点" % [
		GRID_COLS, GRID_ROWS, BOX_POSITIONS.size(), total_cells, targets.size()])


# ============================================================
# 游戏逻辑
# ============================================================
func can_move_to(col: int, row: int) -> bool:
	if not (col >= 0 and col < GRID_COLS and row >= 0 and row < GRID_ROWS):
		return false
	if LEVEL_GRID[row][col] == 1:
		return false
	if is_box_cell(Vector2i(col, row)):
		return false
	return true


## 该格是否为可放置箱子的地板（在界内且非墙，不考虑是否已有箱子）。
func _is_floor(cell: Vector2i) -> bool:
	if not (cell.x >= 0 and cell.x < GRID_COLS and cell.y >= 0 and cell.y < GRID_ROWS):
		return false
	return LEVEL_GRID[cell.y][cell.x] != 1


## --- 箱子(四联通刚体) 辅助 ---
func _rebuild_occ() -> void:
	_occ.clear()
	for i in boxes.size():
		for c in boxes[i]:
			_occ[c] = i

func is_box_cell(cell: Vector2i) -> bool:
	return _occ.has(cell)

func box_index_at(cell: Vector2i) -> int:
	return _occ.get(cell, -1)


## X 键机制：把所有"与玩家相邻(4 邻接,正交)的箱子"——包括大箱子——
## 以玩家为中心顺时针旋转 90 度。每个箱子的所有格子各自绕玩家枢轴旋转：
##   相对坐标 (dx,dy) -> (-dy, dx)   即网格坐标下的顺时针 90°。
## 旋转生效的条件：所有被旋转箱子的目标格子都界内、非墙，
## 且不与"未参与旋转的箱子"或彼此冲突(无两格落到同一位置)。
func rotate_adjacent_boxes() -> void:
	if won:
		return

	_save_state()

	var ap = _ap()
	var center := Vector2i(int(ap["col"]), int(ap["row"]))

	# 1. 找出所有与玩家相邻的箱子索引(去重)。相邻 = 4 邻接(正交)。
	var rot_indices := {}
	for o in [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]:
		var bi := box_index_at(center + o)
		if bi != -1:
			rot_indices[bi] = true

	if rot_indices.is_empty():
		print("  [X] 周围没有可旋转的箱子")
		return

	# 2. 计算每个旋转箱子的目标格子(绕玩家顺时针 90°: (dx,dy)->(-dy,dx))
	var new_cells := {}   # bi -> Array[Vector2i]
	var ok := true
	for bi in rot_indices.keys():
		var dests := []
		for c in boxes[bi]:
			var rel: Vector2i = c - center
			var nd := Vector2i(-rel.y, rel.x) + center
			if not _is_floor(nd):
				ok = false
				break
			var occ := box_index_at(nd)
			# 被"不参与本次旋转"的箱子占据则挡住(旋转中的箱子会让出)
			if occ != -1 and not rot_indices.has(occ):
				ok = false
				break
			dests.append(nd)
		if not ok:
			break
		new_cells[bi] = dests

	# 3. 检查被旋转箱子之间的目标格冲突(含同一箱子两格重合)
	if ok:
		var claimed := {}
		for bi in new_cells.keys():
			for nd in new_cells[bi]:
				if claimed.has(nd):
					ok = false
					break
				claimed[nd] = bi
			if not ok:
				break

	if not ok:
		print("  [X] 旋转被阻挡")
		return

	# 4. 应用
	for bi in new_cells.keys():
		boxes[bi] = new_cells[bi]
	_rebuild_occ()

	move_count += 1
	won = _check_win()
	_update_objects()
	print("  [%d] 旋转箱子(%d 个)" % [move_count, rot_indices.size()])
	if won:
		var new_record := ScoreStore.record_win(LEVEL_PATH, move_count)
		print("\n%s" % "=".repeat(40))
		print("  恭喜通关! 共 %d 步%s" % [move_count, "（新纪录!）" if new_record else ""])
		print("  按 R 重新开始 | ESC 返回选关。")
		print("%s\n" % "=".repeat(40))
		_update_objects()


func move(dx: int, dy: int) -> void:
	if won:
		return

	_save_state()

	var ap = _ap()
	var new_col: int = ap["col"] + dx
	var new_row: int = ap["row"] + dy
	var target_cell := Vector2i(new_col, new_row)

	# 目标格子有箱子 → 尝试推动整个"四联通刚体"箱子
	var pushed := false
	var bi := box_index_at(target_cell)
	if bi != -1:
		var step := Vector2i(dx, dy)
		var can_push := true
		# 箱子整体平移: 每一个格子都能移入合法空位(或移动到同箱另一格)
		for c in boxes[bi]:
			var dest: Vector2i = c + step
			if not (dest.x >= 0 and dest.x < GRID_COLS \
					and dest.y >= 0 and dest.y < GRID_ROWS):
				can_push = false
				break
			if LEVEL_GRID[dest.y][dest.x] == 1:
				can_push = false
				break
			# 被另一(不同)箱子占据则推不动
			var other := box_index_at(dest)
			if other != -1 and other != bi:
				can_push = false
				break
		if can_push:
			var moved_cells: Array[Vector2i] = []
			for c in boxes[bi]:
				moved_cells.append(c + step)
			boxes[bi] = moved_cells
			_rebuild_occ()
			pushed = true

	# 检查玩家能否进入目标格
	if not can_move_to(new_col, new_row):
		return

	# 移动玩家
	ap["col"] = new_col
	ap["row"] = new_row
	ap["facing"] = Vector2i(dx, dy)
	move_count += 1

	# 检查胜利：所有箱子都在目标点上
	won = _check_win()

	_update_objects()

	var action := "推动箱子!" if pushed else "移动"
	print("  [%d] %s → 玩家%d(%d,%d)" % [move_count, action, _active_player + 1, int(ap["col"]), int(ap["row"])])
	if won:
		var new_record := ScoreStore.record_win(LEVEL_PATH, move_count)
		print("\n%s" % "=".repeat(40))
		print("  恭喜通关! 共 %d 步%s" % [move_count, "（新纪录!）" if new_record else ""])
		print("  按 R 重新开始 | ESC 返回选关。")
		print("%s\n" % "=".repeat(40))
		_update_objects()  # 刷新 HUD 显示纪录信息


func _check_win() -> bool:
	# 每个目标点上有箱子即通关(不要求所有箱子格都在目标上)
	for t in targets.keys():
		if not _occ.has(t):
			return false
	return true


func reset_game() -> void:
	_players.clear()
	_active_player = 0
	for ps in PLAYER_STARTS:
		_players.append({"col": ps.x, "row": ps.y, "facing": Vector2i(0, 1)})
	boxes.clear()
	for b in BOX_POSITIONS:
		boxes.append(b.duplicate())
	_rebuild_occ()
	move_count = 0
	_undo_stack.clear()
	won = false
	_reset_box_objects()
	_update_objects()


# ============================================================
# 场景更新
# ============================================================
func _reset_box_objects() -> void:
	# 将箱子网格重新对应到初始位置
	var objs := _box_objs.values()
	_box_objs.clear()
	var i := 0
	for b in BOX_POSITIONS:
		for bp in b:
			if i < objs.size():
				var obj: MeshInstance3D = objs[i]
				obj.position = grid_to_world(bp.x, bp.y, CELL_SIZE / 2.0)
				_box_objs[bp] = obj
				i += 1


func _update_objects() -> void:
	if _player_objs.is_empty():
		return

	# HUD
	if _hud_label != null:
		var head := "[%s]  " % LEVEL_NAME
		if won:
			var best := ScoreStore.get_best(LEVEL_PATH)
			_hud_label.text = head + "步数: %d   |   通关! 最短纪录: %d 步   |   V 切换  ESC 返回" % [move_count, best]
		else:
			_hud_label.text = head + "步数: %d | 玩家%d/%d  |  WASD X Z V R ESC" % [move_count, _active_player + 1, _players.size()]

	# 所有玩家位置
	for pi in _players.size():
		var p = _players[pi]
		_player_objs[pi].position = grid_to_world(p["col"], p["row"], CELL_SIZE / 2.0)
		var facing := p["facing"] as Vector2i
		var yaw := _facing_to_yaw_for(facing)
		_player_objs[pi].rotation.y = yaw

	# 光标跟随活跃玩家
	var ap = _ap()
	_cursor_obj.position = grid_to_world(ap["col"], ap["row"], 0.0)

	# 摄像机 (跟随活跃玩家)
	_update_cam()

	# 箱子位置：重建 (col,row) -> object 映射 (所有箱子格子的集合)
	var occ_now: Dictionary = {}
	for b in boxes:
		for c in b:
			occ_now[c] = true
	var new_box_map := {}
	var unused: Array = []
	for old_pos in _box_objs.keys():
		if occ_now.has(old_pos):
			new_box_map[old_pos] = _box_objs[old_pos]
		else:
			unused.append(_box_objs[old_pos])
	for new_pos in occ_now.keys():
		if not new_box_map.has(new_pos):
			if unused.size() > 0:
				var obj: MeshInstance3D = unused.pop_front()
				obj.position = grid_to_world(new_pos.x, new_pos.y, CELL_SIZE / 2.0)
				new_box_map[new_pos] = obj
	_box_objs = new_box_map

	# 目标点材质高亮
	for pos in _target_objs.keys():
		var t: MeshInstance3D = _target_objs[pos]
		if occ_now.has(pos):
			t.material_override = mat_win_target
		else:
			t.material_override = mat_target

	# 多格箱子桥接
	_rebuild_bridges()


## 为所有多格箱子在相邻格子间创建桥接长方体，填平 0.92 → 1.0 的缝隙。
func _rebuild_bridges() -> void:
	for node in _bridge_nodes:
		node.queue_free()
	_bridge_nodes.clear()

	for b in boxes:
		if b.size() <= 1:
			continue
		var cell_set := {}
		for c in b:
			cell_set[c] = true
		var done := {}
		for c in b:
			for d in [Vector2i(1, 0), Vector2i(0, 1)]:
				var n: Vector2i = c + d
				if not cell_set.has(n):
					continue
				var key := "%d,%d-%d,%d" % [c.x, c.y, n.x, n.y]
				if done.has(key):
					continue
				done[key] = true
				var w1 := grid_to_world(c.x, c.y, CELL_SIZE / 2.0)
				var w2 := grid_to_world(n.x, n.y, CELL_SIZE / 2.0)
				var mid := (w1 + w2) / 2.0
				var bridge_size: Vector3
				if d.y == 0:   # 水平相邻 (col 方向 = X)
					bridge_size = Vector3(CELL_SIZE * 0.1, CELL_SIZE * 0.92, CELL_SIZE * 0.92)
				else:           # 垂直相邻 (row 方向 = Z)
					bridge_size = Vector3(CELL_SIZE * 0.92, CELL_SIZE * 0.92, CELL_SIZE * 0.1)
				var bmesh := BoxMesh.new()
				bmesh.size = bridge_size
				var node := MeshInstance3D.new()
				node.mesh = bmesh
				node.material_override = mat_box
				node.position = mid
				add_child(node)
				_bridge_nodes.append(node)


## 网格方向 → Y 旋转角。
func _facing_to_yaw_for(facing: Vector2i) -> float:
	match facing:
		Vector2i(0, -1): return 0.0
		Vector2i(1, 0):  return PI / 2.0
		Vector2i(0, 1):  return PI
		Vector2i(-1, 0): return -PI / 2.0
	return 0.0


## 世界 XZ 方向 → 最近网格四方向。
func _cam_to_grid(dir: Vector3) -> Vector2i:
	var cardinals := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
	var world := [Vector3(0, 0, -1), Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(-1, 0, 0)]
	var best := 0
	var best_dot := -INF
	for i in 4:
		var d := dir.dot(world[i])
		if d > best_dot:
			best_dot = d
			best = i
	return cardinals[best]


## 保存当前游戏状态到回退栈。
func _save_state() -> void:
	var boxes_copy := []
	for b in boxes:
		boxes_copy.append(b.duplicate())
	var players_copy := []
	for p in _players:
		players_copy.append(p.duplicate())
	_undo_stack.append({
		"players": players_copy,
		"boxes": boxes_copy,
		"moves": move_count,
		"active": _active_player,
	})


## 回退一步（Z 键）。
func _undo() -> void:
	if _undo_stack.is_empty():
		return
	var s = _undo_stack.pop_back()
	_players = s["players"]
	_active_player = s["active"]
	boxes = s["boxes"]
	move_count = s["moves"]
	won = false
	_rebuild_occ()
	_update_objects()
	print("  [Z] 回退到第 %d 步" % move_count)


## 固定俯视角摄像机，按 _cam_angle 绕注视点旋转。
func _update_cam() -> void:
	if _cam == null:
		return
	var offset := _tp_pos - _tp_look
	var rotated := offset.rotated(Vector3.UP, _cam_angle)
	_cam.position = _tp_look + rotated
	_cam.look_at(_tp_look, Vector3.UP)


# ============================================================
# 输入处理
# ============================================================
func _unhandled_input(event: InputEvent) -> void:
	# --- 键盘事件: 游戏操作 ---
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return

	var key := event as InputEventKey

	if key.keycode == KEY_ESCAPE:
		get_tree().change_scene_to_file(SELECT_SCENE)
		return

	if key.keycode == KEY_R:
		_cam_angle += PI / 2.0
		_update_cam()
		print("  [R] 旋转视角")
		return

	if key.keycode == KEY_X:
		var now_x := Time.get_ticks_msec() / 1000.0
		if now_x - _last_move_time < 0.08:
			return
		_last_move_time = now_x
		rotate_adjacent_boxes()
		return

	if key.keycode == KEY_Z:
		_undo()
		return

	if key.keycode == KEY_V:
		_active_player = (_active_player + 1) % _players.size()
		_update_objects()
		print("  [V] 切换到玩家%d" % (_active_player + 1))
		return

	var dx := 0
	var dy := 0
	# WASD 随摄像头朝向，方向键始终绝对方向
	var fwd := Vector3(sin(_cam_angle), 0, -cos(_cam_angle))
	var right := Vector3(cos(_cam_angle), 0, sin(_cam_angle))
	match key.keycode:
		KEY_W:
			var gd := _cam_to_grid(fwd)
			dx = gd.x; dy = gd.y
		KEY_S:
			var gd := _cam_to_grid(-fwd)
			dx = gd.x; dy = gd.y
		KEY_A:
			var gd := _cam_to_grid(-right)
			dx = gd.x; dy = gd.y
		KEY_D:
			var gd := _cam_to_grid(right)
			dx = gd.x; dy = gd.y
		KEY_UP:    dy = -1
		KEY_DOWN:  dy = 1
		KEY_LEFT:  dx = -1
		KEY_RIGHT: dx = 1
		_:
			return

	# 防连按
	var now := Time.get_ticks_msec() / 1000.0
	if now - _last_move_time < 0.08:
		return
	_last_move_time = now

	move(dx, dy)
