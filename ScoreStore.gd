class_name ScoreStore
extends RefCounted
##
## 通关成绩存档
## ============
## 记录每个关卡的历史最短通关步数，持久化到 user:// 目录。
## 关卡以文件名（如 level_01.txt）作为键。
##

const SAVE_PATH := "user://sokoban_scores.cfg"
const SECTION := "best_moves"


## 记录一次通关成绩；仅当比历史最短更好（或首次通关）时更新。
## 返回 true 表示刷新了纪录。
static func record_win(level_path: String, moves: int) -> bool:
	var key := level_path.get_file()
	var cfg := ConfigFile.new()
	cfg.load(SAVE_PATH)  # 文件不存在时返回错误码，忽略即可（当作空存档）

	var best := int(cfg.get_value(SECTION, key, -1))
	if best != -1 and best <= moves:
		return false

	cfg.set_value(SECTION, key, moves)
	var err := cfg.save(SAVE_PATH)
	if err != OK:
		push_error("成绩保存失败: %s" % error_string(err))
		return false
	return true


## 获取某关卡的历史最短步数；未通关过返回 -1。
static func get_best(level_path: String) -> int:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return -1
	return int(cfg.get_value(SECTION, level_path.get_file(), -1))


## 是否通关过该关卡。
static func is_completed(level_path: String) -> bool:
	return get_best(level_path) >= 0
