class_name LevelLoader
extends RefCounted
##
## 关卡加载器
## ==========
## 从 txt 文件解析 Sokoban 关卡，供选关界面与主游戏共用。
##
## 地图字符含义:
##   #  墙
##   (空格) 地板
##   .  目标点
##   $  单个箱子(1x1)，每个 $ 各自独立
##   *  单个箱子(1x1)且已在目标点上
##   1-9,0  多格箱子: 相同数字归为同一个箱子
##   @  玩家0 (起点，可有多个)    +  玩家0 在目标点上
##   a  玩家1 起点              A  玩家1 在目标点上
##   b  玩家2 起点              B  玩家2 在目标点上   …依此类推至 z/Z
## 以 ; 开头的行为关卡名/注释，第一条注释作为关卡显示名。
##

const LEVELS_DIR := "res://levels"

# 场景间传递当前选中的关卡路径
static var selected_level_path: String = ""


## 解析一个关卡文件，返回字典:
## {
##   "name": String,
##   "grid": Array[Array[int]],   # 0=地板 1=墙 2=目标点
##   "cols": int, "rows": int,
##   "boxes": Array[Array[Vector2i]],   # 每个元素 = 一个箱子的所有格子
##   "player_starts": Array[Vector2i],  # 玩家起点列表，索引0=@, 1=a, 2=b…
##   "ok": bool, "error": String,
## }
static func load_level(path: String) -> Dictionary:
	var result := {
		"name": path.get_file(),
		"grid": [],
		"cols": 0,
		"rows": 0,
		"boxes": [],
		"player_starts": [],
		"ok": false,
		"error": "",
	}

	if not FileAccess.file_exists(path):
		result.error = "文件不存在: " + path
		return result

	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		result.error = "无法打开文件: " + path
		return result

	var raw_lines: Array[String] = []
	var name_set := false
	while not f.eof_reached():
		var line := f.get_line()
		# 去掉行尾回车（Windows CRLF）
		line = line.trim_suffix("\r")
		if line.begins_with(";"):
			if not name_set:
				result.name = line.substr(1).strip_edges()
				name_set = true
			continue
		raw_lines.append(line)
	f.close()

	# 去掉末尾的空行
	while raw_lines.size() > 0 and raw_lines[raw_lines.size() - 1].strip_edges() == "":
		raw_lines.remove_at(raw_lines.size() - 1)

	if raw_lines.is_empty():
		result.error = "关卡没有有效地图行"
		return result

	# 计算最大列宽（不同行可能长度不一，右侧补地板）
	var cols := 0
	for l in raw_lines:
		cols = max(cols, l.length())
	var rows := raw_lines.size()

	var grid: Array = []
	var single_boxes: Array = []      # 每个 $/* 各自一个 1x1 箱子
	var digit_groups: Dictionary = {}  # 数字 -> 该数字标记的箱子格子列表
	var player_starts: Array = []     # Array[Vector2i], 索引0=@,1=a,2=b…

	for row in range(rows):
		var line: String = raw_lines[row]
		var grid_row: Array = []
		for col in range(cols):
			var ch := " "
			if col < line.length():
				ch = line[col]
			var cell := 0  # 默认地板
			if ch >= "0" and ch <= "9":
				cell = 0
				var d := ch.to_int()
				if not digit_groups.has(d):
					digit_groups[d] = []
				digit_groups[d].append(Vector2i(col, row))
			else:
				match ch:
					"#":
						cell = 1
					".":
						cell = 2
					"*":
						cell = 2
						single_boxes.append([Vector2i(col, row)])
					"$":
						cell = 0
						single_boxes.append([Vector2i(col, row)])
					"@":
						cell = 0
						_add_player_at(player_starts, 0, Vector2i(col, row))
					"+":
						cell = 2
						_add_player_at(player_starts, 0, Vector2i(col, row))
					_:
						match _extra_player(ch):
							[var pi, var on_target]:
								cell = 2 if on_target else 0
								_add_player_at(player_starts, pi, Vector2i(col, row))
							_:
								cell = 0

	# 组合所有箱子: 单格箱子($/*) + 数字分组箱子(由用户显式用相同数字标出)
	var cell_boxes: Array = []
	for sb in single_boxes:
		cell_boxes.append(sb)
	for d in digit_groups.keys():
		cell_boxes.append(digit_groups[d])

	if player_starts.is_empty():
		result.error = "关卡缺少玩家起点 (@)"
		return result

	result.grid = grid
	result.cols = cols
	result.rows = rows
	result.boxes = cell_boxes
	result.player_starts = player_starts
	result.ok = true
	return result


## 解析额外玩家字符: a=1, A=1且目标上, b=2, B=2目标上… 返回 [玩家索引, 是否在目标上]; 非玩家字符返回 null。
static func _extra_player(ch: String) -> Array:
	if ch >= "a" and ch <= "z":
		return [ch.unicode_at(0) - "a".unicode_at(0) + 1, false]
	if ch >= "A" and ch <= "Z":
		return [ch.unicode_at(0) - "A".unicode_at(0) + 1, true]
	return []


## 确保玩家索引位置存在后存入。保证数组连续(插空位)。
static func _add_player_at(arr: Array, idx: int, pos: Vector2i) -> void:
	while arr.size() <= idx:
		arr.append(Vector2i.ZERO)
	arr[idx] = pos


## 列出 levels 目录下所有关卡文件路径（按文件名排序）。
static func list_levels() -> Array[String]:
	var paths: Array[String] = []
	var dir := DirAccess.open(LEVELS_DIR)
	if dir == null:
		push_error("无法打开关卡目录: " + LEVELS_DIR)
		return paths
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.get_extension().to_lower() == "txt":
			paths.append(LEVELS_DIR + "/" + fname)
		fname = dir.get_next()
	dir.list_dir_end()
	paths.sort()
	return paths
