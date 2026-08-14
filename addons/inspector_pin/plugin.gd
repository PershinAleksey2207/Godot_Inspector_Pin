@tool
extends EditorPlugin

## Pins the Inspector to one object, so it stops following the selection.
##
## Three buttons are added to the Inspector header, left of the node-name
## dropdown:
##
## [b]Pin[/b] — the Inspector keeps showing the pinned object while you select
## other nodes and switch scene tabs. Drilling into a sub-resource still works;
## the pin only reacts to selection changes.
##
## [b]Save[/b] — saves the scene the pinned node belongs to and rebuilds its
## instances, without you having to switch to its tab first.
##
## [b]Live[/b] — mirrors edits into instances of that scene in the scene you are
## looking at, then saves shortly afterwards. This is what lets you tune a value
## on a node from one scene while watching the result in another.

const AUTO_TOOLTIP := "Live preview.\nMirror edits into instances of the pinned node's scene in the open scene, then auto-save."
const PIN_TOOLTIP := "Pin the Inspector to the selected node.\nThe Inspector will keep showing it while you select other nodes."
const SAVE_TOOLTIP_IDLE := "Save the scene the pinned node belongs to."

## Quiet period after the last edit before an auto-save fires.
const AUTO_SAVE_DELAY := 0.3

## How far up from the inspector to look for the dock holding the header row.
const ANCESTOR_SEARCH_LIMIT := 8

## The node-name dropdown, newest class name first. Godot 4.7 renamed
## EditorPath to EditorObjectSelector; both are listed so the addon keeps
## working on either side of that rename.
const OBJECT_SELECTOR_CLASSES := ["EditorObjectSelector", "EditorPath"]

var _pin_button: Button
var _save_button: Button
var _auto_button: Button

var _pinned: Object = null
var _restore_queued := false
var _saving := false

## Seconds left before a queued auto-save fires; negative means nothing queued.
var _save_countdown := -1.0

## Last seen value of every storable property on the pinned node, used to spot
## edits by comparison rather than by signal.
var _watched := {}


func _enter_tree() -> void:
	_build_buttons()
	_inject_buttons()
	EditorInterface.get_selection().selection_changed.connect(_on_selection_changed)
	_update_ui()


func _exit_tree() -> void:
	var selection := EditorInterface.get_selection()
	if selection.selection_changed.is_connected(_on_selection_changed):
		selection.selection_changed.disconnect(_on_selection_changed)

	# Drop the pin without touching the Inspector — the editor owns it from here.
	_pinned = null
	_reset_watch()
	set_process(false)

	for button in [_pin_button, _save_button, _auto_button]:
		if is_instance_valid(button):
			if button.get_parent() != null:
				button.get_parent().remove_child(button)
			button.queue_free()
	_pin_button = null
	_save_button = null
	_auto_button = null


func _edited_scene_changed() -> void:
	_queue_restore()


func _process(delta: float) -> void:
	# Catches the pinned node being freed, e.g. its scene tab was closed.
	if _pinned != null and not is_instance_valid(_pinned):
		_clear_pin()
		return

	if _live_enabled() and _has_pin():
		_poll_pinned_changes()

	if _save_countdown < 0.0:
		return
	_save_countdown -= delta
	if _save_countdown > 0.0:
		return

	# A save can rebuild the Inspector and yank the widget out from under the
	# cursor. Waiting for the mouse to come up keeps a slider drag intact, and
	# collapses a whole drag into a single write.
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_save_countdown = AUTO_SAVE_DELAY
		return

	_save_countdown = -1.0
	_save_without_switching_tabs()


# --- UI -----------------------------------------------------------------------

func _build_buttons() -> void:
	_pin_button = _make_button("InspectorPinButton", ["Pin"], "Pin", PIN_TOOLTIP, true)
	_pin_button.toggled.connect(_on_pin_toggled)

	_save_button = _make_button("InspectorPinSaveButton", ["Save"], "Save", SAVE_TOOLTIP_IDLE, false)
	_save_button.pressed.connect(_on_save_pressed)

	_auto_button = _make_button("InspectorPinLiveButton", ["AutoKey", "Reload"], "Live", AUTO_TOOLTIP, true)
	_auto_button.toggled.connect(_on_live_toggled)


## Icon names are tried in order; the label is only used if none of them exist
## in the editor theme, which keeps the button usable on an unfamiliar version.
func _make_button(node_name: String, icon_names: Array, label: String, tooltip: String, toggles: bool) -> Button:
	var button := Button.new()
	button.name = node_name
	button.toggle_mode = toggles
	button.theme_type_variation = "FlatButton"
	button.focus_mode = Control.FOCUS_NONE
	button.tooltip_text = tooltip
	var icon := _editor_icon(icon_names)
	if icon != null:
		button.icon = icon
	else:
		button.text = label
	return button


## Places the buttons on the row that holds the node-name dropdown, just to the
## left of it. Bound by class name rather than child index, so a reshuffle of the
## dock's header cannot silently drop them somewhere else.
func _inject_buttons() -> void:
	var selector := _find_object_selector()
	if selector == null:
		push_warning("Inspector Pin: the node-name dropdown was not found, so the buttons were not installed. Expected one of %s.\nInspector dock contents:\n%s" % [OBJECT_SELECTOR_CLASSES, _describe_dock()])
		return

	var row := selector.get_parent()
	if not (row is Container):
		push_warning("Inspector Pin: the node-name dropdown is not in a container; buttons not installed.")
		return

	var at := selector.get_index()
	for button in [_pin_button, _save_button, _auto_button]:
		row.add_child(button)
		row.move_child(button, at)
		at += 1


## The inspector sits a few wrapper levels below the dock that owns the header,
## and how many levels that is has changed between Godot versions. So walk up
## from the inspector and search each ancestor's subtree until the node-name
## dropdown turns up.
func _find_object_selector() -> Node:
	var ancestor := EditorInterface.get_inspector().get_parent()
	var levels := 0
	while ancestor != null and levels < ANCESTOR_SEARCH_LIMIT:
		for candidate in OBJECT_SELECTOR_CLASSES:
			var found := _find_by_class(ancestor, candidate)
			if found != null:
				return found
		ancestor = ancestor.get_parent()
		levels += 1
	return null


func _update_ui() -> void:
	# All three are touched below, and a hot script reload can leave a newly
	# added one null until _enter_tree runs again.
	if not is_instance_valid(_pin_button) or not is_instance_valid(_save_button) or not is_instance_valid(_auto_button):
		return

	var pinned := _has_pin()
	_pin_button.set_pressed_no_signal(pinned)
	_pin_button.tooltip_text = "Inspector pinned to: %s\nClick to unpin." % _pinned_label() if pinned else PIN_TOOLTIP

	var path := _pinned_scene_path()
	_save_button.disabled = path.is_empty()
	_auto_button.disabled = path.is_empty()
	if path.is_empty():
		_save_button.tooltip_text = SAVE_TOOLTIP_IDLE
		_auto_button.tooltip_text = AUTO_TOOLTIP
	else:
		_save_button.tooltip_text = "Save %s and rebuild its instances.\nBriefly switches scene tabs." % path
		_auto_button.tooltip_text = "Live preview: mirror edits into instances of\n%s in the open scene, then auto-save.\nAlso saves every open scene with unsaved changes." % path


# --- Pin ----------------------------------------------------------------------

func _on_pin_toggled(pressed: bool) -> void:
	if pressed:
		var target := _current_inspected_object()
		if target == null:
			_pin_button.set_pressed_no_signal(false)
			_update_ui()
			return
		_pinned = target
		set_process(true)
		_begin_watch()
	else:
		_pinned = null
		_reset_watch()
		set_process(false)
		# Hand the Inspector back to whatever is selected right now.
		var selected := EditorInterface.get_selection().get_selected_nodes()
		if not selected.is_empty():
			EditorInterface.inspect_object(selected[0])

	_update_ui()


func _on_selection_changed() -> void:
	_queue_restore()


func _queue_restore() -> void:
	if not _has_pin() or _restore_queued:
		return
	_restore_queued = true
	# Deferred so the editor's own handler puts the new selection in the
	# Inspector first and we override it afterwards, not the other way round.
	_restore_pinned.call_deferred()


func _restore_pinned() -> void:
	_restore_queued = false
	if not _has_pin():
		_clear_pin()
		return
	# Re-inspecting rebuilds the whole property list, which would collapse open
	# sections and drop any widget mid-interaction. Only do it if the Inspector
	# has actually drifted off the pinned object.
	var inspector := EditorInterface.get_inspector()
	if not inspector.has_method("get_edited_object") or inspector.get_edited_object() != _pinned:
		EditorInterface.inspect_object(_pinned)
	_update_ui()


func _clear_pin() -> void:
	_pinned = null
	_reset_watch()
	set_process(false)
	_update_ui()


func _has_pin() -> bool:
	return _pinned != null and is_instance_valid(_pinned)


func _current_inspected_object() -> Object:
	var inspector := EditorInterface.get_inspector()
	if inspector.has_method("get_edited_object"):
		var edited: Object = inspector.get_edited_object()
		if edited != null:
			return edited
	var selected := EditorInterface.get_selection().get_selected_nodes()
	if not selected.is_empty():
		return selected[0]
	return null


func _pinned_label() -> String:
	return (_pinned as Node).name if _pinned is Node else _pinned.get_class()


# --- Live preview -------------------------------------------------------------

func _on_live_toggled(pressed: bool) -> void:
	if pressed:
		_begin_watch()
	else:
		_reset_watch()


func _live_enabled() -> bool:
	return is_instance_valid(_auto_button) and _auto_button.button_pressed


## Snapshots the pinned node so later frames can tell what changed.
func _begin_watch() -> void:
	_watched.clear()
	if not _has_pin():
		return
	for info in _pinned.get_property_list():
		if info.usage & PROPERTY_USAGE_STORAGE:
			_watched[info.name] = _fingerprint(_pinned.get(info.name))


func _reset_watch() -> void:
	_watched.clear()
	_save_countdown = -1.0


## Object-valued properties are reduced to an id. Keeping the object itself
## would hold a reference to every resource on the node for as long as the pin
## lasts, and would leave this dictionary holding pointers to things the editor
## may free between frames.
func _fingerprint(value: Variant) -> Variant:
	if value is Object:
		return (value as Object).get_instance_id() if is_instance_valid(value) else 0
	return value


## EditorInspector.property_edited is not dependable here: editors that stream
## intermediate values — the colour picker above all — mark them as "changing"
## and stay silent until the popup closes. Comparing against a snapshot catches
## every edit as it happens, whatever the property editor reports, and picks up
## undo/redo for free.
func _poll_pinned_changes() -> void:
	var touched := false
	for name in _watched:
		var current: Variant = _fingerprint(_pinned.get(name))
		var previous: Variant = _watched[name]
		# Compare types first. GDScript raises on '!=' between incomparable
		# types, and a stale snapshot left by a hot script reload is enough to
		# hit that on every frame.
		if typeof(current) != typeof(previous) or current != previous:
			_watched[name] = current
			_mirror_property(name)
			touched = true
	if touched:
		_save_countdown = AUTO_SAVE_DELAY


## Godot only refreshes sub-scene instances when their scene is saved as the
## current tab, and that tab flip is visible on every save. So instead of
## relying on it, push the edited value straight into the instances sitting in
## the scene on screen. The auto-save that follows writes the source file, which
## brings the two back into agreement — so nothing is left behind to be baked
## into the open scene as an instance override.
func _mirror_property(property: StringName) -> void:
	var source_path := _pinned_scene_path()
	if source_path.is_empty() or not (_pinned is Node):
		return

	var pinned_node := _pinned as Node
	var source_root := _scene_root_of(pinned_node)
	var current_root := EditorInterface.get_edited_scene_root()
	if current_root == null or current_root == source_root:
		return  # The pinned node's own scene is on screen; it already redraws.

	var relative := source_root.get_path_to(pinned_node)
	var value: Variant = pinned_node.get(property)
	for instance in _find_instances_of(current_root, source_path):
		var twin := instance.get_node_or_null(relative)
		if twin != null:
			twin.set(property, value)


## Every node in the open scene that was instanced from the given scene file.
func _find_instances_of(node: Node, scene_path: String) -> Array[Node]:
	var found: Array[Node] = []
	if node.scene_file_path == scene_path:
		found.append(node)
	for child in node.get_children():
		found.append_array(_find_instances_of(child, scene_path))
	return found


# --- Save ---------------------------------------------------------------------

## A node's owner is the root of the scene it was authored in; a scene root owns
## itself.
func _scene_root_of(node: Node) -> Node:
	return node.owner if node.owner != null else node


func _pinned_scene_path() -> String:
	if not _has_pin() or not (_pinned is Node):
		return ""
	return _scene_root_of(_pinned as Node).scene_file_path


## The manual button takes the slower, complete route. Switching to the pinned
## node's scene and saving it there is what makes Godot rebuild its instances,
## which picks up structural edits that property mirroring cannot cover. The
## viewport flips briefly, which is acceptable for a deliberate click.
func _on_save_pressed() -> void:
	var target_path := _pinned_scene_path()
	if target_path.is_empty() or _saving:
		return

	var current_root := EditorInterface.get_edited_scene_root()
	var current_path := current_root.scene_file_path if current_root != null else ""
	if current_path == target_path or current_path.is_empty():
		EditorInterface.save_scene()
		return

	_saving = true
	EditorInterface.open_scene_from_path(target_path)
	await get_tree().process_frame
	EditorInterface.save_scene()
	await get_tree().process_frame
	EditorInterface.open_scene_from_path(current_path)
	await get_tree().process_frame
	_saving = false
	_queue_restore()


## The auto-save path. Godot has no "save that one open scene" call, and the tab
## switch above is too disruptive to repeat on every edit. save_all_scenes()
## leaves the tabs alone; the viewport is already correct because the live
## preview updated it as the value changed. The cost is that it also writes any
## other open scene with unsaved changes.
func _save_without_switching_tabs() -> void:
	if _pinned_scene_path().is_empty():
		return
	EditorInterface.save_all_scenes()


# --- Helpers ------------------------------------------------------------------

func _editor_icon(icon_names: Array) -> Texture2D:
	var theme := EditorInterface.get_editor_theme()
	if theme == null:
		return null
	for icon_name in icon_names:
		if theme.has_icon(icon_name, "EditorIcons"):
			return theme.get_icon(icon_name, "EditorIcons")
	return null


func _find_by_class(node: Node, target_class: String) -> Node:
	if node.get_class() == target_class:
		return node
	for child in node.get_children(true):
		var found := _find_by_class(child, target_class)
		if found != null:
			return found
	return null


## Dumps the dock's own widgets, skipping the EditorInspector subtree — that
## part is the property list and would bury the header row we care about. Only
## used to make a failed install diagnosable from the editor log.
func _describe_dock() -> String:
	var dock := EditorInterface.get_inspector().get_parent()
	var levels := 0
	while dock != null and dock.get_class() != "InspectorDock" and levels < ANCESTOR_SEARCH_LIMIT:
		dock = dock.get_parent()
		levels += 1
	if dock == null:
		return "(InspectorDock not found among ancestors)"
	return _describe_subtree(dock, 0)


func _describe_subtree(node: Node, depth: int) -> String:
	var out := "%s- %s (%s)\n" % ["  ".repeat(depth), node.name, node.get_class()]
	if node.get_class() == "EditorInspector" or depth >= 4:
		return out
	for child in node.get_children(true):
		out += _describe_subtree(child, depth + 1)
	return out
