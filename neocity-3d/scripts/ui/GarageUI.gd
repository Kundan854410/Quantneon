## GarageUI
## -----------------------------------------------------------------------------
## 3D showroom + full customization UI for the Vehicle Customization Workshop.
##
## Responsibilities:
##   * Builds a 3D showroom scene (SubViewport) with rotating platform, studio
##     lighting, and orbit camera controls.
##   * Hosts tabs for Paint, Decals, Wheels, Spoiler, Exhaust, Underglow,
##     Performance and Marketplace.
##   * Before / after comparison slider that wipes between two snapshots.
##   * Purchase confirmation dialog with token cost breakdown.
##   * "My Collection" grid showing all owned configurations with thumbnails.
##   * Live spider chart driven by PerformanceUpgrades.spider_chart_points().
##
## The UI is built entirely in code so it doesn't require a matching .tscn.
## Drop this Node under a CanvasLayer and assign the three NodePaths (vehicle,
## customizer, performance, marketplace) — everything else initializes itself.
extends Control
class_name GarageUI

## -----------------------------------------------------------------------------
## Signals
## -----------------------------------------------------------------------------
signal purchase_requested(total_cost: int)
signal purchase_confirmed(total_cost: int)
signal purchase_cancelled()
signal tab_changed(tab_name: String)
signal collection_item_selected(config_name: String)

## -----------------------------------------------------------------------------
## Constants
## -----------------------------------------------------------------------------
const SHOWROOM_BG: Color = Color(0.04, 0.05, 0.09)
const ACCENT_COLOR: Color = Color(0.2, 0.85, 1.0)
const PANEL_BG: Color = Color(0.08, 0.10, 0.15, 0.92)
const TEXT_MUTED: Color = Color(0.75, 0.8, 0.9)

const TAB_PAINT: String = "Paint"
const TAB_DECALS: String = "Decals"
const TAB_WHEELS: String = "Wheels"
const TAB_SPOILER: String = "Spoiler"
const TAB_EXHAUST: String = "Exhaust"
const TAB_UNDERGLOW: String = "Underglow"
const TAB_PERFORMANCE: String = "Performance"
const TAB_COLLECTION: String = "My Collection"
const TAB_MARKETPLACE: String = "Marketplace"

const ALL_TABS: Array[String] = [
	TAB_PAINT,
	TAB_DECALS,
	TAB_WHEELS,
	TAB_SPOILER,
	TAB_EXHAUST,
	TAB_UNDERGLOW,
	TAB_PERFORMANCE,
	TAB_COLLECTION,
	TAB_MARKETPLACE,
]

const PLATFORM_RADIUS: float = 2.6
const CAMERA_MIN_DISTANCE: float = 3.5
const CAMERA_MAX_DISTANCE: float = 9.0
const CAMERA_MIN_PITCH: float = -0.3
const CAMERA_MAX_PITCH: float = 1.2

## -----------------------------------------------------------------------------
## Exported fields
## -----------------------------------------------------------------------------
@export_node_path("Node3D") var vehicle_path: NodePath
@export_node_path("Node") var customizer_path: NodePath
@export_node_path("Node") var performance_path: NodePath
@export_node_path("Node") var marketplace_path: NodePath
@export var auto_rotate: bool = true
@export var auto_rotate_speed_deg_s: float = 14.0

## -----------------------------------------------------------------------------
## External references
## -----------------------------------------------------------------------------
var _vehicle: Node3D = null
var _customizer: Node = null
var _performance: Node = null
var _marketplace: Node = null

## -----------------------------------------------------------------------------
## 3D showroom state
## -----------------------------------------------------------------------------
var _viewport: SubViewport = null
var _viewport_container: SubViewportContainer = null
var _showroom_root: Node3D = null
var _platform: Node3D = null
var _camera_rig: Node3D = null
var _camera_yaw: Node3D = null
var _camera_pitch: Node3D = null
var _camera: Camera3D = null
var _studio_lights: Array = []

var _camera_distance: float = 5.5
var _camera_yaw_rad: float = 0.0
var _camera_pitch_rad: float = 0.4
var _dragging: bool = false
var _platform_rotation: float = 0.0

## -----------------------------------------------------------------------------
## Layout state
## -----------------------------------------------------------------------------
var _root_h: HSplitContainer = null
var _left_panel: VBoxContainer = null
var _tab_bar: HBoxContainer = null
var _tab_content: Control = null
var _status_label: Label = null
var _token_label: Label = null

var _current_tab: String = TAB_PAINT
var _tab_buttons: Dictionary = {}   # name -> Button

## Before / after snapshot compare
var _before_image: Image = null
var _after_image: Image = null
var _compare_overlay: Control = null
var _compare_slider_value: float = 0.5

## Pending purchase state
var _pending_cost: int = 0
var _confirm_dialog: ConfirmationDialog = null

## Spider chart (drawn in code, refreshes on perf updates)
var _spider_chart_control: Control = null

## -----------------------------------------------------------------------------
## Lifecycle
## -----------------------------------------------------------------------------
func _ready() -> void:
	name = "GarageUI"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_PASS

	_resolve_external_refs()
	_build_layout()
	_build_showroom()
	_switch_tab(TAB_PAINT)
	_refresh_status()
	_refresh_spider_chart()

func _resolve_external_refs() -> void:
	if vehicle_path != NodePath(""):
		_vehicle = get_node_or_null(vehicle_path)
	if customizer_path != NodePath(""):
		_customizer = get_node_or_null(customizer_path)
	if performance_path != NodePath(""):
		_performance = get_node_or_null(performance_path)
	if marketplace_path != NodePath(""):
		_marketplace = get_node_or_null(marketplace_path)
	if _performance and _performance.has_signal("stats_recomputed"):
		_performance.connect("stats_recomputed", Callable(self, "_on_stats_recomputed"))
	if _customizer and _customizer.has_signal("paint_changed"):
		_customizer.connect("paint_changed", Callable(self, "_on_any_customizer_change"))

## -----------------------------------------------------------------------------
## Layout construction
## -----------------------------------------------------------------------------
func _build_layout() -> void:
	var bg := ColorRect.new()
	bg.color = SHOWROOM_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	_root_h = HSplitContainer.new()
	_root_h.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root_h.split_offset = 640
	add_child(_root_h)

	# ------------------------------------------------------------------ left: 3D
	_viewport_container = SubViewportContainer.new()
	_viewport_container.stretch = true
	_viewport_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_viewport_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_viewport_container.custom_minimum_size = Vector2(480, 480)
	_viewport_container.gui_input.connect(_on_viewport_gui_input)
	_root_h.add_child(_viewport_container)

	_viewport = SubViewport.new()
	_viewport.size = Vector2i(960, 720)
	_viewport.transparent_bg = false
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport_container.add_child(_viewport)

	# Compare overlay — sits on top of the viewport container.
	_compare_overlay = Control.new()
	_compare_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_compare_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_compare_overlay.draw.connect(_draw_compare_overlay)
	_compare_overlay.hide()
	_viewport_container.add_child(_compare_overlay)

	# ----------------------------------------------------------------- right: UI
	_left_panel = VBoxContainer.new()
	_left_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_left_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_left_panel.add_theme_constant_override("separation", 8)
	_root_h.add_child(_left_panel)

	# Header with title + token balance
	var header := HBoxContainer.new()
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_left_panel.add_child(header)

	var title := Label.new()
	title.text = "NEO GARAGE — CUSTOMIZATION WORKSHOP"
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", ACCENT_COLOR)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)

	_token_label = Label.new()
	_token_label.text = "0 QNT"
	_token_label.add_theme_color_override("font_color", Color(1.0, 0.88, 0.25))
	_token_label.add_theme_font_size_override("font_size", 18)
	header.add_child(_token_label)

	# Tab bar
	_tab_bar = HBoxContainer.new()
	_tab_bar.add_theme_constant_override("separation", 4)
	_left_panel.add_child(_tab_bar)
	for name in ALL_TABS:
		var btn := Button.new()
		btn.text = name
		btn.toggle_mode = true
		btn.pressed.connect(func(): _switch_tab(name))
		_tab_bar.add_child(btn)
		_tab_buttons[name] = btn

	# Tab content host
	_tab_content = PanelContainer.new()
	_tab_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tab_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var panel_sb := StyleBoxFlat.new()
	panel_sb.bg_color = PANEL_BG
	panel_sb.corner_radius_top_left = 6
	panel_sb.corner_radius_top_right = 6
	panel_sb.corner_radius_bottom_left = 6
	panel_sb.corner_radius_bottom_right = 6
	_tab_content.add_theme_stylebox_override("panel", panel_sb)
	_left_panel.add_child(_tab_content)

	# Footer: status, buy button, compare button.
	var footer := HBoxContainer.new()
	_left_panel.add_child(footer)

	_status_label = Label.new()
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_label.add_theme_color_override("font_color", TEXT_MUTED)
	footer.add_child(_status_label)

	var compare_btn := Button.new()
	compare_btn.text = "Capture Before"
	compare_btn.pressed.connect(_capture_before)
	footer.add_child(compare_btn)

	var compare_btn2 := Button.new()
	compare_btn2.text = "Capture After"
	compare_btn2.pressed.connect(_capture_after)
	footer.add_child(compare_btn2)

	var compare_btn3 := Button.new()
	compare_btn3.text = "Toggle Compare"
	compare_btn3.pressed.connect(_toggle_compare)
	footer.add_child(compare_btn3)

	var buy_btn := Button.new()
	buy_btn.text = "Purchase Configuration"
	buy_btn.pressed.connect(_on_purchase_clicked)
	footer.add_child(buy_btn)

	# Confirm dialog
	_confirm_dialog = ConfirmationDialog.new()
	_confirm_dialog.title = "Confirm Purchase"
	_confirm_dialog.dialog_hide_on_ok = true
	_confirm_dialog.confirmed.connect(_on_confirm_dialog_confirmed)
	_confirm_dialog.canceled.connect(_on_confirm_dialog_canceled)
	add_child(_confirm_dialog)

## -----------------------------------------------------------------------------
## Showroom construction
## -----------------------------------------------------------------------------
func _build_showroom() -> void:
	_showroom_root = Node3D.new()
	_showroom_root.name = "ShowroomRoot"
	_viewport.add_child(_showroom_root)

	# Environment
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.02, 0.03, 0.08)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.15, 0.2, 0.3)
	e.ambient_light_energy = 0.5
	e.fog_enabled = true
	e.fog_light_color = Color(0.05, 0.08, 0.18)
	e.fog_density = 0.02
	e.glow_enabled = true
	e.glow_intensity = 1.2
	env.environment = e
	_showroom_root.add_child(env)

	# Floor
	var floor := MeshInstance3D.new()
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(40, 40)
	floor.mesh = floor_mesh
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.05, 0.07, 0.12)
	floor_mat.metallic = 0.5
	floor_mat.roughness = 0.2
	floor.material_override = floor_mat
	_showroom_root.add_child(floor)

	# Rotating platform
	_platform = Node3D.new()
	_platform.name = "Platform"
	_showroom_root.add_child(_platform)

	var platform_mesh := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = PLATFORM_RADIUS
	cyl.bottom_radius = PLATFORM_RADIUS
	cyl.height = 0.1
	platform_mesh.mesh = cyl
	platform_mesh.position = Vector3(0, 0.05, 0)
	var platform_mat := StandardMaterial3D.new()
	platform_mat.albedo_color = Color(0.12, 0.14, 0.22)
	platform_mat.metallic = 0.8
	platform_mat.roughness = 0.15
	platform_mat.emission_enabled = true
	platform_mat.emission = ACCENT_COLOR
	platform_mat.emission_energy_multiplier = 0.25
	platform_mesh.material_override = platform_mat
	_platform.add_child(platform_mesh)

	# Glowing ring
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = PLATFORM_RADIUS - 0.08
	tm.outer_radius = PLATFORM_RADIUS
	ring.mesh = tm
	var ring_mat := StandardMaterial3D.new()
	ring_mat.albedo_color = ACCENT_COLOR
	ring_mat.emission_enabled = true
	ring_mat.emission = ACCENT_COLOR
	ring_mat.emission_energy_multiplier = 3.0
	ring.material_override = ring_mat
	ring.rotation = Vector3(PI * 0.5, 0, 0)
	ring.position = Vector3(0, 0.1, 0)
	_platform.add_child(ring)

	# Studio lights
	for angle_deg in [45.0, 135.0, 225.0, 315.0]:
		var angle: float = deg_to_rad(angle_deg)
		var spot := SpotLight3D.new()
		spot.light_color = Color(1.0, 0.98, 0.95) if angle_deg == 45.0 else Color(0.85, 0.9, 1.0)
		spot.light_energy = 3.5
		spot.spot_range = 14.0
		spot.spot_angle = 35.0
		spot.spot_angle_attenuation = 0.8
		spot.position = Vector3(cos(angle) * 5.5, 5.0, sin(angle) * 5.5)
		spot.look_at(Vector3.ZERO, Vector3.UP)
		_showroom_root.add_child(spot)
		_studio_lights.append(spot)

	# Key rim light (magenta)
	var rim := OmniLight3D.new()
	rim.light_color = Color(1.0, 0.3, 1.0)
	rim.light_energy = 2.0
	rim.omni_range = 9.0
	rim.position = Vector3(-4.0, 2.0, -3.5)
	_showroom_root.add_child(rim)
	_studio_lights.append(rim)

	# Re-parent the vehicle (if any) into the platform so it rotates.
	if _vehicle != null and _vehicle.get_parent() != _platform:
		var original_parent := _vehicle.get_parent()
		if original_parent != null:
			original_parent.remove_child(_vehicle)
		_platform.add_child(_vehicle)
		_vehicle.position = Vector3.ZERO

	# Camera rig: yaw (Y-axis) -> pitch (X-axis) -> camera offset (Z).
	_camera_rig = Node3D.new()
	_camera_rig.name = "CameraRig"
	_showroom_root.add_child(_camera_rig)
	_camera_yaw = Node3D.new()
	_camera_rig.add_child(_camera_yaw)
	_camera_pitch = Node3D.new()
	_camera_yaw.add_child(_camera_pitch)
	_camera = Camera3D.new()
	_camera.fov = 45.0
	_camera.near = 0.05
	_camera.far = 200.0
	_camera_pitch.add_child(_camera)
	_update_camera_transform()

## -----------------------------------------------------------------------------
## Process — platform rotation + camera animation
## -----------------------------------------------------------------------------
func _process(delta: float) -> void:
	if auto_rotate and _platform != null:
		_platform_rotation += deg_to_rad(auto_rotate_speed_deg_s) * delta
		_platform.rotation = Vector3(0, _platform_rotation, 0)

func _update_camera_transform() -> void:
	if _camera == null or _camera_yaw == null or _camera_pitch == null:
		return
	_camera_yaw.rotation = Vector3(0, _camera_yaw_rad, 0)
	_camera_pitch.rotation = Vector3(-_camera_pitch_rad, 0, 0)
	_camera.position = Vector3(0, 0, _camera_distance)

## -----------------------------------------------------------------------------
## Viewport input — orbit / zoom / drag-to-pause-rotation
## -----------------------------------------------------------------------------
func _on_viewport_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mb.pressed
			if mb.pressed:
				auto_rotate = false
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_camera_distance = clamp(_camera_distance - 0.4, CAMERA_MIN_DISTANCE, CAMERA_MAX_DISTANCE)
			_update_camera_transform()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_camera_distance = clamp(_camera_distance + 0.4, CAMERA_MIN_DISTANCE, CAMERA_MAX_DISTANCE)
			_update_camera_transform()
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		_camera_yaw_rad -= mm.relative.x * 0.008
		_camera_pitch_rad = clamp(_camera_pitch_rad + mm.relative.y * 0.006, CAMERA_MIN_PITCH, CAMERA_MAX_PITCH)
		_update_camera_transform()
	elif event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and k.keycode == KEY_R:
			auto_rotate = not auto_rotate

## -----------------------------------------------------------------------------
## Tabs
## -----------------------------------------------------------------------------
func _switch_tab(tab_name: String) -> void:
	if not (tab_name in ALL_TABS):
		return
	_current_tab = tab_name
	for n in _tab_buttons.keys():
		var b: Button = _tab_buttons[n]
		b.button_pressed = (n == tab_name)
	# Wipe content
	for c in _tab_content.get_children():
		c.queue_free()
	var body: Control = null
	match tab_name:
		TAB_PAINT: body = _build_paint_panel()
		TAB_DECALS: body = _build_decals_panel()
		TAB_WHEELS: body = _build_wheels_panel()
		TAB_SPOILER: body = _build_spoiler_panel()
		TAB_EXHAUST: body = _build_exhaust_panel()
		TAB_UNDERGLOW: body = _build_underglow_panel()
		TAB_PERFORMANCE: body = _build_performance_panel()
		TAB_COLLECTION: body = _build_collection_panel()
		TAB_MARKETPLACE: body = _build_marketplace_panel()
	if body != null:
		_tab_content.add_child(body)
	emit_signal("tab_changed", tab_name)

## ---------------------------- Paint panel ------------------------------------
func _build_paint_panel() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)

	var color_label := Label.new()
	color_label.text = "Body Color (HSV)"
	v.add_child(color_label)

	var picker := ColorPicker.new()
	picker.color = _customizer.paint_color if _customizer else Color(0.9, 0.1, 0.1)
	picker.edit_alpha = false
	picker.color_changed.connect(func(c):
		if _customizer:
			_customizer.set_paint(c, _customizer.paint_finish)
			_refresh_status())
	v.add_child(picker)

	var finish_label := Label.new()
	finish_label.text = "Finish"
	v.add_child(finish_label)

	var finishes := HBoxContainer.new()
	v.add_child(finishes)
	var finish_options := ["metallic", "matte", "chrome", "pearlescent"]
	for f in finish_options:
		var btn := Button.new()
		btn.text = f.capitalize()
		btn.toggle_mode = true
		if _customizer and _customizer.paint_finish == f:
			btn.button_pressed = true
		btn.pressed.connect(func():
			if _customizer:
				_customizer.set_paint_finish(f)
				_switch_tab(TAB_PAINT))
		finishes.add_child(btn)

	var pearl_label := Label.new()
	pearl_label.text = "Pearlescent shift color"
	v.add_child(pearl_label)

	var pearl_picker := ColorPicker.new()
	pearl_picker.color = _customizer.paint_pearl_shift if _customizer else Color(0.2, 0.4, 1.0)
	pearl_picker.edit_alpha = false
	pearl_picker.color_changed.connect(func(c):
		if _customizer:
			_customizer.set_pearl_shift(c))
	v.add_child(pearl_picker)
	return _wrap_scroll(v)

## ---------------------------- Decals panel -----------------------------------
func _build_decals_panel() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)

	var slot_row := HBoxContainer.new()
	var slot_label := Label.new()
	slot_label.text = "Target Slot"
	slot_row.add_child(slot_label)
	var slot_option := OptionButton.new()
	slot_option.name = "SlotOption"
	for i in range(6):
		slot_option.add_item(_decal_slot_name(i), i)
	slot_row.add_child(slot_option)
	var remove_btn := Button.new()
	remove_btn.text = "Remove From Slot"
	remove_btn.pressed.connect(func():
		if _customizer:
			_customizer.remove_decal(slot_option.get_selected_id())
			_refresh_status())
	slot_row.add_child(remove_btn)
	var clear_btn := Button.new()
	clear_btn.text = "Clear All"
	clear_btn.pressed.connect(func():
		if _customizer:
			_customizer.clear_all_decals()
			_refresh_status())
	slot_row.add_child(clear_btn)
	v.add_child(slot_row)

	# Category filter
	var cat_row := HBoxContainer.new()
	var cat_label := Label.new()
	cat_label.text = "Category"
	cat_row.add_child(cat_label)
	var cat_option := OptionButton.new()
	cat_option.add_item("All", 0)
	var categories: Array = []
	if _customizer:
		for id in _customizer.DECAL_CATALOGUE.keys():
			var c = _customizer.DECAL_CATALOGUE[id].get("category", "")
			if not (c in categories):
				categories.append(c)
	for i in range(categories.size()):
		cat_option.add_item(categories[i], i + 1)
	cat_row.add_child(cat_option)
	v.add_child(cat_row)

	# Scrollable grid of decal buttons
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 320)
	var grid := GridContainer.new()
	grid.columns = 3
	scroll.add_child(grid)
	v.add_child(scroll)

	var _populate_decal_grid = func():
		for c in grid.get_children():
			c.queue_free()
		if _customizer == null:
			return
		var selected_cat_id: int = cat_option.get_selected_id()
		var cat_name: String = "" if selected_cat_id == 0 else String(cat_option.get_item_text(cat_option.get_item_index(selected_cat_id)))
		for decal_id in _customizer.DECAL_CATALOGUE.keys():
			var info: Dictionary = _customizer.DECAL_CATALOGUE[decal_id]
			if cat_name != "" and info.get("category", "") != cat_name:
				continue
			var btn := Button.new()
			btn.text = "%s\n%s · %d QNT" % [info.get("name", decal_id), info.get("rarity", ""), int(info.get("price", 0))]
			btn.custom_minimum_size = Vector2(150, 60)
			btn.pressed.connect(func():
				_customizer.apply_decal(slot_option.get_selected_id(), decal_id)
				_refresh_status())
			grid.add_child(btn)
	cat_option.item_selected.connect(func(_i): _populate_decal_grid.call())
	_populate_decal_grid.call()
	return v

func _decal_slot_name(slot: int) -> String:
	match slot:
		0: return "Hood"
		1: return "Roof"
		2: return "Trunk"
		3: return "Left Door"
		4: return "Right Door"
		5: return "Rear Window"
	return "Slot " + str(slot)

## ---------------------------- Wheels panel -----------------------------------
func _build_wheels_panel() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 360)
	var grid := GridContainer.new()
	grid.columns = 2
	scroll.add_child(grid)
	v.add_child(scroll)
	if _customizer:
		for id in _customizer.WHEEL_CATALOGUE.keys():
			var info: Dictionary = _customizer.WHEEL_CATALOGUE[id]
			var btn := Button.new()
			btn.text = "%s\n%s · %d QNT" % [info.get("name", id), info.get("rarity", ""), int(info.get("price", 0))]
			btn.custom_minimum_size = Vector2(220, 60)
			btn.pressed.connect(func():
				_customizer.set_wheels(id)
				_refresh_status())
			grid.add_child(btn)
	return v

## ---------------------------- Spoiler panel ----------------------------------
func _build_spoiler_panel() -> Control:
	var v := VBoxContainer.new()
	if _customizer:
		for id in _customizer.SPOILER_CATALOGUE.keys():
			var info: Dictionary = _customizer.SPOILER_CATALOGUE[id]
			var btn := Button.new()
			btn.text = "%s — downforce %.2f · drag %.2f · %d QNT" % [
				info.get("name", id),
				float(info.get("downforce", 0.0)),
				float(info.get("drag", 0.0)),
				int(info.get("price", 0)),
			]
			btn.pressed.connect(func():
				_customizer.set_spoiler(id)
				_refresh_status())
			v.add_child(btn)
	return _wrap_scroll(v)

## ---------------------------- Exhaust panel ----------------------------------
func _build_exhaust_panel() -> Control:
	var v := VBoxContainer.new()
	if _customizer:
		for id in _customizer.EXHAUST_CATALOGUE.keys():
			var info: Dictionary = _customizer.EXHAUST_CATALOGUE[id]
			var btn := Button.new()
			btn.text = "%s — %d tip(s) · %s · %d dB · %d QNT" % [
				info.get("name", id),
				int(info.get("tip_count", 1)),
				String(info.get("tone", "")),
				int(info.get("db", 0)),
				int(info.get("price", 0)),
			]
			btn.pressed.connect(func():
				_customizer.set_exhaust(id)
				_refresh_status())
			v.add_child(btn)
	return _wrap_scroll(v)

## ---------------------------- Underglow panel --------------------------------
func _build_underglow_panel() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	var lbl := Label.new()
	lbl.text = "Underglow Color"
	v.add_child(lbl)
	var picker := ColorPicker.new()
	picker.color = _customizer.underglow_color if _customizer else Color(0.1, 0.6, 1.0)
	picker.edit_alpha = false
	picker.color_changed.connect(func(c):
		if _customizer:
			_customizer.set_underglow(c, _customizer.underglow_pattern, _customizer.underglow_intensity))
	v.add_child(picker)

	var pat_row := HBoxContainer.new()
	v.add_child(pat_row)
	var patterns = ["off", "solid", "pulse", "strobe", "chase", "rainbow"]
	for p in patterns:
		var btn := Button.new()
		btn.text = p.capitalize()
		btn.toggle_mode = true
		if _customizer and _customizer.underglow_pattern == p:
			btn.button_pressed = true
		btn.pressed.connect(func():
			if _customizer:
				_customizer.set_underglow(_customizer.underglow_color, p, _customizer.underglow_intensity)
				_switch_tab(TAB_UNDERGLOW))
		pat_row.add_child(btn)

	var slider_label := Label.new()
	slider_label.text = "Intensity"
	v.add_child(slider_label)
	var intensity := HSlider.new()
	intensity.min_value = 0.0
	intensity.max_value = 3.0
	intensity.step = 0.05
	intensity.value = _customizer.underglow_intensity if _customizer else 1.0
	intensity.value_changed.connect(func(val):
		if _customizer:
			_customizer.set_underglow(_customizer.underglow_color, _customizer.underglow_pattern, val))
	v.add_child(intensity)
	return v

## ---------------------------- Performance panel ------------------------------
func _build_performance_panel() -> Control:
	var root_h := HBoxContainer.new()
	root_h.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# Left column: upgrade list
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root_h.add_child(v)
	if _performance:
		for cat in _performance.ALL_CATEGORIES:
			var row := HBoxContainer.new()
			var lbl := Label.new()
			lbl.text = "%s: %s" % [cat.capitalize(), _performance.current_tier_of(cat)]
			lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(lbl)
			var cost: int = _performance.cost_for_next_tier(cat)
			var up_btn := Button.new()
			if cost > 0:
				up_btn.text = "Upgrade (%d QNT)" % cost
			else:
				up_btn.text = "Maxed"
				up_btn.disabled = true
			up_btn.pressed.connect(func():
				_performance.purchase_next_tier(cat)
				_switch_tab(TAB_PERFORMANCE)
				_refresh_status())
			row.add_child(up_btn)
			var refund_btn := Button.new()
			refund_btn.text = "Refund"
			refund_btn.disabled = (_performance.current_tier_of(cat) == _performance.TIER_STOCK)
			refund_btn.pressed.connect(func():
				_performance.refund_current_tier(cat)
				_switch_tab(TAB_PERFORMANCE)
				_refresh_status())
			row.add_child(refund_btn)
			v.add_child(row)

		var reset_row := HBoxContainer.new()
		var reset_btn := Button.new()
		reset_btn.text = "Reset All To Stock"
		reset_btn.pressed.connect(func():
			_performance.reset_all()
			_switch_tab(TAB_PERFORMANCE)
			_refresh_status())
		reset_row.add_child(reset_btn)
		v.add_child(reset_row)

	# Right column: spider chart
	_spider_chart_control = Control.new()
	_spider_chart_control.custom_minimum_size = Vector2(260, 260)
	_spider_chart_control.draw.connect(_draw_spider_chart)
	root_h.add_child(_spider_chart_control)

	return root_h

## ---------------------------- Collection panel -------------------------------
func _build_collection_panel() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)

	# Save current configuration as named preset.
	var save_row := HBoxContainer.new()
	var name_edit := LineEdit.new()
	name_edit.placeholder_text = "Preset name"
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_row.add_child(name_edit)
	var save_btn := Button.new()
	save_btn.text = "Save Current Build"
	save_btn.pressed.connect(func():
		if _customizer and name_edit.text.strip_edges() != "":
			_customizer.save_configuration(name_edit.text.strip_edges())
			_switch_tab(TAB_COLLECTION))
	save_row.add_child(save_btn)
	v.add_child(save_row)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 360)
	var grid := VBoxContainer.new()
	scroll.add_child(grid)
	v.add_child(scroll)

	if _customizer:
		for cfg_name in _customizer.list_saved_configurations():
			var item_row := HBoxContainer.new()
			var lbl := Label.new()
			lbl.text = cfg_name
			lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			item_row.add_child(lbl)
			var load_btn := Button.new()
			load_btn.text = "Load"
			load_btn.pressed.connect(func():
				_customizer.load_configuration(cfg_name)
				emit_signal("collection_item_selected", cfg_name)
				_refresh_status())
			item_row.add_child(load_btn)
			var del_btn := Button.new()
			del_btn.text = "Delete"
			del_btn.pressed.connect(func():
				_customizer.delete_configuration(cfg_name)
				_switch_tab(TAB_COLLECTION))
			item_row.add_child(del_btn)
			grid.add_child(item_row)
	return v

## ---------------------------- Marketplace panel ------------------------------
func _build_marketplace_panel() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	if _marketplace == null:
		var lbl := Label.new()
		lbl.text = "Marketplace not connected."
		v.add_child(lbl)
		return v

	# Sell current build
	var sell_row := HBoxContainer.new()
	var title_edit := LineEdit.new()
	title_edit.placeholder_text = "Listing title"
	title_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sell_row.add_child(title_edit)
	var price_edit := SpinBox.new()
	price_edit.min_value = 1
	price_edit.max_value = 1_000_000
	price_edit.step = 50
	price_edit.value = 500
	sell_row.add_child(price_edit)
	var sell_btn := Button.new()
	sell_btn.text = "List Instant"
	sell_btn.pressed.connect(func():
		if _customizer and _performance:
			_marketplace.create_instant_listing(
				_customizer.export_configuration(),
				_performance.export_state(),
				int(price_edit.value),
				title_edit.text,
			)
			_switch_tab(TAB_MARKETPLACE))
	sell_row.add_child(sell_btn)
	var auction_btn := Button.new()
	auction_btn.text = "List Auction (24h)"
	auction_btn.pressed.connect(func():
		if _customizer and _performance:
			_marketplace.create_auction_listing(
				_customizer.export_configuration(),
				_performance.export_state(),
				int(price_edit.value),
				86400,
				title_edit.text,
			)
			_switch_tab(TAB_MARKETPLACE))
	sell_row.add_child(auction_btn)
	v.add_child(sell_row)

	# Trending leaderboard
	var trend_label := Label.new()
	trend_label.text = "Trending Builds"
	trend_label.add_theme_color_override("font_color", ACCENT_COLOR)
	v.add_child(trend_label)

	var trending := _marketplace.leaderboard_trending(8)
	var trend_list := VBoxContainer.new()
	for entry in trending:
		var row := HBoxContainer.new()
		var e_label := Label.new()
		e_label.text = "%s — by %s — score %.1f" % [entry.get("title", ""), entry.get("seller", ""), float(entry.get("score", 0.0))]
		e_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(e_label)
		trend_list.add_child(row)
	v.add_child(trend_list)

	# Active listings
	var listings_label := Label.new()
	listings_label.text = "Active Listings"
	listings_label.add_theme_color_override("font_color", ACCENT_COLOR)
	v.add_child(listings_label)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 260)
	var list_v := VBoxContainer.new()
	scroll.add_child(list_v)
	v.add_child(scroll)

	for l in _marketplace.list_all_active():
		var row := HBoxContainer.new()
		var label := Label.new()
		label.text = _marketplace.describe_listing(l.id)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)
		if l.kind == _marketplace.LISTING_KIND_INSTANT:
			var buy_btn := Button.new()
			buy_btn.text = "Buy"
			buy_btn.pressed.connect(func():
				_marketplace.buy_instant(l.id)
				_switch_tab(TAB_MARKETPLACE))
			row.add_child(buy_btn)
		else:
			var bid_spin := SpinBox.new()
			bid_spin.min_value = _marketplace.min_next_bid(l.id)
			bid_spin.max_value = 10_000_000
			bid_spin.step = 50
			bid_spin.value = bid_spin.min_value
			row.add_child(bid_spin)
			var bid_btn := Button.new()
			bid_btn.text = "Bid"
			bid_btn.pressed.connect(func():
				_marketplace.place_bid(l.id, int(bid_spin.value))
				_switch_tab(TAB_MARKETPLACE))
			row.add_child(bid_btn)
		list_v.add_child(row)
	return v

## -----------------------------------------------------------------------------
## Before/after compare overlay
## -----------------------------------------------------------------------------
func _capture_before() -> void:
	if _customizer:
		_before_image = _grab_viewport_image()
		_status_label.text = "Captured 'before' snapshot."

func _capture_after() -> void:
	if _customizer:
		_after_image = _grab_viewport_image()
		_status_label.text = "Captured 'after' snapshot."

func _grab_viewport_image() -> Image:
	if _viewport == null:
		return null
	var tex := _viewport.get_texture()
	if tex == null:
		return null
	return tex.get_image()

func _toggle_compare() -> void:
	if _before_image == null or _after_image == null:
		_status_label.text = "Need both before and after snapshots."
		return
	_compare_overlay.visible = not _compare_overlay.visible
	_compare_overlay.queue_redraw()

func _draw_compare_overlay() -> void:
	if _compare_overlay == null:
		return
	var rect := _compare_overlay.get_rect()
	if _before_image == null or _after_image == null:
		return
	var before_tex := ImageTexture.create_from_image(_before_image)
	var after_tex := ImageTexture.create_from_image(_after_image)
	var split_x: float = rect.size.x * _compare_slider_value
	# Left half — before
	var left_rect := Rect2(Vector2.ZERO, Vector2(split_x, rect.size.y))
	_compare_overlay.draw_texture_rect_region(before_tex, left_rect, Rect2(Vector2.ZERO, Vector2(before_tex.get_size().x * _compare_slider_value, before_tex.get_size().y)))
	# Right half — after
	var right_rect := Rect2(Vector2(split_x, 0), Vector2(rect.size.x - split_x, rect.size.y))
	var after_start_x: float = after_tex.get_size().x * _compare_slider_value
	_compare_overlay.draw_texture_rect_region(after_tex, right_rect, Rect2(Vector2(after_start_x, 0), Vector2(after_tex.get_size().x - after_start_x, after_tex.get_size().y)))
	# Divider
	_compare_overlay.draw_line(Vector2(split_x, 0), Vector2(split_x, rect.size.y), ACCENT_COLOR, 2.0)
	_compare_overlay.draw_string(ThemeDB.fallback_font, Vector2(8, 20), "BEFORE", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(1, 1, 1))
	_compare_overlay.draw_string(ThemeDB.fallback_font, Vector2(rect.size.x - 80, 20), "AFTER", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(1, 1, 1))

func _gui_input(event: InputEvent) -> void:
	if _compare_overlay.visible and event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if mm.button_mask & MOUSE_BUTTON_MASK_LEFT != 0:
			var rect := _compare_overlay.get_rect()
			_compare_slider_value = clamp((mm.position.x - rect.position.x) / rect.size.x, 0.0, 1.0)
			_compare_overlay.queue_redraw()

## -----------------------------------------------------------------------------
## Spider chart renderer
## -----------------------------------------------------------------------------
func _draw_spider_chart() -> void:
	if _performance == null or _spider_chart_control == null:
		return
	var size := _spider_chart_control.size
	var center := size * 0.5
	var radius: float = min(size.x, size.y) * 0.42

	# Rings
	for ring in [0.25, 0.5, 0.75, 1.0]:
		var pts := PackedVector2Array()
		for i in range(5):
			var angle: float = -PI * 0.5 + TAU * float(i) / 5.0
			pts.append(center + Vector2(cos(angle), sin(angle)) * radius * ring)
		pts.append(pts[0])
		_spider_chart_control.draw_polyline(pts, Color(1, 1, 1, 0.15), 1.0)

	# Axes
	for i in range(5):
		var angle: float = -PI * 0.5 + TAU * float(i) / 5.0
		var tip := center + Vector2(cos(angle), sin(angle)) * radius
		_spider_chart_control.draw_line(center, tip, Color(1, 1, 1, 0.25), 1.0)

	# Data polygon
	var poly := _performance.build_spider_polygon(center, radius)
	var fill_color := ACCENT_COLOR
	fill_color.a = 0.35
	var closed := PackedVector2Array(poly)
	if closed.size() > 0:
		closed.append(closed[0])
	_spider_chart_control.draw_colored_polygon(poly, fill_color)
	_spider_chart_control.draw_polyline(closed, ACCENT_COLOR, 2.0)

	# Labels
	var labels := _performance.spider_chart_labels()
	for i in range(labels.size()):
		var angle: float = -PI * 0.5 + TAU * float(i) / float(labels.size())
		var label_pos := center + Vector2(cos(angle), sin(angle)) * (radius + 14.0) - Vector2(22, 6)
		_spider_chart_control.draw_string(ThemeDB.fallback_font, label_pos, labels[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1, 1, 1))

func _refresh_spider_chart() -> void:
	if _spider_chart_control != null:
		_spider_chart_control.queue_redraw()

## -----------------------------------------------------------------------------
## Purchase flow
## -----------------------------------------------------------------------------
func _on_purchase_clicked() -> void:
	if _customizer == null:
		return
	_pending_cost = _customizer.total_configuration_price()
	emit_signal("purchase_requested", _pending_cost)
	_confirm_dialog.dialog_text = "Purchase this configuration for %d QNT?\n\n%s" % [_pending_cost, _customizer.summary_string()]
	_confirm_dialog.popup_centered(Vector2i(480, 240))

func _on_confirm_dialog_confirmed() -> void:
	if _performance != null:
		if _performance.token_balance < _pending_cost:
			_status_label.text = "Insufficient tokens."
			return
		_performance.token_balance -= _pending_cost
	emit_signal("purchase_confirmed", _pending_cost)
	_status_label.text = "Purchased for %d QNT." % _pending_cost
	_refresh_status()

func _on_confirm_dialog_canceled() -> void:
	emit_signal("purchase_cancelled")

## -----------------------------------------------------------------------------
## Signal handlers
## -----------------------------------------------------------------------------
func _on_stats_recomputed(_stats: Dictionary) -> void:
	_refresh_spider_chart()
	_refresh_status()

func _on_any_customizer_change(_a = null, _b = null) -> void:
	_refresh_status()

## -----------------------------------------------------------------------------
## Status helpers
## -----------------------------------------------------------------------------
func _refresh_status() -> void:
	if _token_label != null and _performance != null:
		_token_label.text = "%d QNT" % _performance.token_balance
	if _status_label != null and _customizer != null:
		_status_label.text = _customizer.summary_string()

func _wrap_scroll(inner: Control) -> Control:
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.custom_minimum_size = Vector2(0, 360)
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(inner)
	return sc

## -----------------------------------------------------------------------------
## Public API — external controllers can drive the UI
## -----------------------------------------------------------------------------
func open_tab(tab_name: String) -> void:
	_switch_tab(tab_name)

func set_vehicle(vehicle: Node3D) -> void:
	_vehicle = vehicle
	if _vehicle and _platform and _vehicle.get_parent() != _platform:
		if _vehicle.get_parent():
			_vehicle.get_parent().remove_child(_vehicle)
		_platform.add_child(_vehicle)
		_vehicle.position = Vector3.ZERO

func set_auto_rotate(enabled: bool) -> void:
	auto_rotate = enabled

func snapshot_showroom() -> Image:
	return _grab_viewport_image()
