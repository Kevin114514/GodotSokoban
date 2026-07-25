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
##   $  单个箱子(1x1)，每个 $ 各自独立，不会与相邻箱子合并
##   *  单个箱子(1x1)且已在目标点上
##   1-9,0  多格箱子: 相同数字的所有格子属于"同一个箱子"(由你显式分组，无需四联通)
##   @  玩家
##   +  玩家在目标点上
## 以 ; 开头的行为关卡名/注释，第一条注释作为关卡显示名。
## 提示: 一个箱子可以是任意形状的格子集合，只要用相同数字标出即可。
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
##   "player_start": Vector2i,
##   "ok": bool, "error": String,
## }
static func load_level(path: String) -> Dictionary:
	var result := {
		"name": path.get_file(),
		"grid": [],
		"cols": 0,
		"rows": 0,
		"boxes": [],
		"player_start": Vector2i(-1, -1),
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
	var player_start := Vector2i(-1, -1)

	for row in range(rows):
		var line: String = raw_lines[row]
		var grid_row: Array = []
		for col in range(cols):
			var ch := " "
			if col < line.length():
				ch = line[col]
			var cell := 0  # 默认地板
			if ch >= "0" and ch <= "9":
				# 多格箱子: 相同数字归为同一个箱子(由用户显式分组，无需四联通)
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
						player_start = Vector2i(col, row)
					"+":
						cell = 2
						player_start = Vector2i(col, row)
					_:
						cell = 0
			grid_row.append(cell)
		grid.append(grid_row)

	# 组合所有箱子: 单格箱子($/*) + 数字分组箱子(由用户显式用相同数字标出)
	var cell_boxes: Array = []
	for sb in single_boxes:
		cell_boxes.append(sb)
	for d in digit_groups.keys():
		cell_boxes.append(digit_groups[d])

	if player_start == Vector2i(-1, -1):
		result.error = "关卡缺少玩家起点 (@)"
		return result

	result.grid = grid
	result.cols = cols
	result.rows = rows
	result.boxes = cell_boxes
	result.player_start = player_start
	result.ok = true
	return result


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
