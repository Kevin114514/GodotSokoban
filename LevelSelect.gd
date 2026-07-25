extends Control
##
## 选关界面
## ========
## 扫描 res://levels/*.txt，为每个关卡生成一个按钮。
## 点击按钮记录选中关卡并切换到主游戏场景。
##

const GAME_SCENE := "res://Main.tscn"

@onready var _list: VBoxContainer = $Center/Panel/Margin/VBox/ScrollList/List


func _ready() -> void:
	_populate()


func _populate() -> void:
	# 清空旧按钮
	for c in _list.get_children():
		c.queue_free()

	var levels := LevelLoader.list_levels()
	if levels.is_empty():
		var lbl := Label.new()
		lbl.text = "未找到关卡文件\n请在 res://levels/ 放置 *.txt"
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_list.add_child(lbl)
		return

	var index := 1
	for path in levels:
		var data := LevelLoader.load_level(path)
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(360, 56)
		if data.ok:
			btn.pressed.connect(_on_level_pressed.bind(path))
			btn.add_child(_make_row(index, data, path))
		else:
			btn.text = "%s (损坏)" % path.get_file()
			btn.add_theme_font_size_override("font_size", 22)
			btn.disabled = true
		_list.add_child(btn)
		index += 1


## 生成按钮内部的行布局：左侧关卡标题（通关后绿色），右侧最短步数。
func _make_row(index: int, data: Dictionary, path: String) -> Control:
	var hbox := HBoxContainer.new()
	hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	hbox.offset_left = 16
	hbox.offset_right = -16
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_theme_constant_override("separation", 12)

	var completed := ScoreStore.is_completed(path)

	var title := Label.new()
	title.text = "%s   (%d 箱)" % [data.name, data.boxes.size()]
	title.add_theme_font_size_override("font_size", 22)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if completed:
		title.add_theme_color_override("font_color", Color(0.2, 0.9, 0.35))
	hbox.add_child(title)

	var best_lbl := Label.new()
	best_lbl.add_theme_font_size_override("font_size", 18)
	best_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	best_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if completed:
		best_lbl.text = "最短 %d 步" % ScoreStore.get_best(path)
		best_lbl.add_theme_color_override("font_color", Color(0.2, 0.9, 0.35))
	else:
		best_lbl.text = "未通关"
		best_lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	hbox.add_child(best_lbl)

	return hbox


func _on_level_pressed(path: String) -> void:
	LevelLoader.selected_level_path = path
	get_tree().change_scene_to_file(GAME_SCENE)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == KEY_ESCAPE:
			get_tree().quit()
