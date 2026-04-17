## CityGenerator — Procedural Cyberpunk City Generation
## Generates city blocks, neon skyscrapers, and interconnected sky-bridges
## at runtime using a seeded, deterministic algorithm.
##
## Architecture overview:
##   • A square grid of CITY_RADIUS×CITY_RADIUS "blocks" is laid out on the XZ plane.
##   • Each block is divided into a 2×2 sub-grid of building lots.
##   • Buildings are BoxMesh instances with the cyber_building shader applied and
##     per-building neon edge-colour variation for visual variety.
##   • Sky-bridges are thin BoxMesh beams that connect the tallest adjacent pairs
##     once all buildings have been placed.
##   • OmniLight3D neon accent lights are scattered at street level and on rooftops.
##   • A simple distance-based LOD system hides/shows buildings every LOD_CHECK_FRAMES
##     frames to keep draw calls low on mobile WebGL targets.

extends Node3D

# ── Tuneable Parameters ──────────────────────────────────────────────────────

## How many blocks extend in each direction from the centre (total = 2*radius × 2*radius).
@export var city_radius: int = 12

## Width/depth of each city block in world units (includes intra-block road).
@export var block_size: float = 40.0

## Width of the road between adjacent blocks.
@export var road_width: float = 8.0

## Minimum/maximum height for a generated building.
@export var min_building_height: float = 8.0
@export var max_building_height: float = 120.0

## Building footprint bounds within a lot (fraction of lot size).
@export var min_footprint: float = 0.5
@export var max_footprint: float = 0.9

## Number of sky-bridges to attempt to spawn per city generate call.
@export var sky_bridge_count: int = 60

## Minimum height at which a building qualifies for a sky-bridge endpoint.
@export var sky_bridge_min_height: float = 40.0

## Street-level neon light count.
@export var street_light_count: int = 80

## Distance beyond which buildings are culled (LOD). Set 0 to disable.
@export var lod_cull_distance: float = 160.0

## Number of physics frames between LOD update sweeps.
@export var lod_check_frames: int = 30

## Seed for the random number generator (0 = random each run).
@export var city_seed: int = 0

# ── Internal state ───────────────────────────────────────────────────────────

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

# Array of {node: MeshInstance3D, world_pos: Vector3} for LOD sweeps.
var _buildings: Array = []

# Preloaded shader material shared by all buildings (set per-instance overrides).
var _building_shader: ShaderMaterial

# Counter for LOD frame throttling.
var _lod_frame: int = 0

# Reference to the local camera for LOD distance calculations.
var _camera: Camera3D

## Fraction of max_building_height applied to supertall spires.
const SUPERTALL_HEIGHT_MULT: float = 1.8
## Footprint fraction applied to supertall spires (narrower profile).
const SUPERTALL_FOOTPRINT_MULT: float = 0.6
## Fraction of max_building_height applied to squat podium blocks.
const PODIUM_HEIGHT_MULT: float = 0.5
## Footprint fraction applied to squat podium blocks (wider profile).
const PODIUM_FOOTPRINT_MULT: float = 1.2
## Probability threshold below which a building becomes a supertall spire.
const SUPERTALL_PROB: float = 0.15
## Probability threshold below which a building becomes a squat podium.
const PODIUM_PROB: float = 0.45

# Neon palette – each building picks a random pair from this list.
const NEON_PALETTE: Array = [
	[Color(1.0, 0.0, 0.8), Color(0.0, 0.8, 1.0)],   # Pink / Cyan
	[Color(0.0, 1.0, 0.4), Color(0.8, 0.0, 1.0)],   # Green / Purple
	[Color(1.0, 0.6, 0.0), Color(0.0, 0.4, 1.0)],   # Amber / Blue
	[Color(1.0, 0.1, 0.1), Color(0.0, 1.0, 0.8)],   # Red / Teal
	[Color(0.9, 1.0, 0.0), Color(0.6, 0.0, 1.0)],   # Yellow / Violet
]

const NEON_LIGHT_COLORS: Array = [
	Color(1.0, 0.0, 0.8, 1.0),
	Color(0.0, 1.0, 1.0, 1.0),
	Color(0.0, 1.0, 0.4, 1.0),
	Color(1.0, 0.5, 0.0, 1.0),
	Color(0.8, 0.0, 1.0, 1.0),
]

# ── Lifecycle ────────────────────────────────────────────────────────────────

func _ready() -> void:
	_rng.seed = city_seed if city_seed != 0 else int(Time.get_ticks_usec())

	_load_building_shader()
	_generate_city()
	_scatter_street_lights()

	print("[CityGenerator] City generation complete. Buildings: %d" % _buildings.size())


func _process(_delta: float) -> void:
	if lod_cull_distance <= 0.0:
		return

	_lod_frame += 1
	if _lod_frame % lod_check_frames != 0:
		return

	_update_lod()


# ── Shader Loading ───────────────────────────────────────────────────────────

func _load_building_shader() -> void:
	var shader = load("res://materials/cyber_building.gdshader") as Shader
	if shader:
		_building_shader = ShaderMaterial.new()
		_building_shader.shader = shader
	else:
		push_warning("[CityGenerator] cyber_building.gdshader not found; falling back to StandardMaterial3D.")


# ── City Generation Entry Point ──────────────────────────────────────────────

func _generate_city() -> void:
	# Collect rooftop anchor positions for sky-bridge generation.
	var tall_rooftops: Array = []  # Array of {pos: Vector3, height: float}

	var stride: float = block_size + road_width

	for grid_x in range(-city_radius, city_radius):
		for grid_z in range(-city_radius, city_radius):
			var block_origin: Vector3 = Vector3(
				grid_x * stride,
				0.0,
				grid_z * stride
			)
			_generate_block(block_origin, tall_rooftops)

	_generate_sky_bridges(tall_rooftops)


# ── Block + Buildings ────────────────────────────────────────────────────────

func _generate_block(origin: Vector3, tall_rooftops: Array) -> void:
	# Each block is split into a 2×2 grid of lots.
	var lot_size: float = (block_size - road_width * 0.5) * 0.5

	for lx in range(2):
		for lz in range(2):
			var lot_origin: Vector3 = origin + Vector3(
				lx * (lot_size + road_width * 0.25),
				0.0,
				lz * (lot_size + road_width * 0.25)
			)
			_generate_building(lot_origin, lot_size, tall_rooftops)


func _generate_building(lot_origin: Vector3, lot_size: float, tall_rooftops: Array) -> void:
	# Randomise footprint within lot.
	var fp_frac: float = _rng.randf_range(min_footprint, max_footprint)
	var fp: float = lot_size * fp_frac

	# Randomly offset within the lot so buildings don't align perfectly.
	var margin: float = (lot_size - fp) * 0.5
	var offset_x: float = _rng.randf_range(-margin, margin)
	var offset_z: float = _rng.randf_range(-margin, margin)

	var height: float = _rng.randf_range(min_building_height, max_building_height)

	# Choose a tiered profile: tall spires are rare, squat blocks common.
	var profile_roll: float = _rng.randf()
	if profile_roll < SUPERTALL_PROB:
		height *= SUPERTALL_HEIGHT_MULT
		fp *= SUPERTALL_FOOTPRINT_MULT
	elif profile_roll < PODIUM_PROB:
		height *= PODIUM_HEIGHT_MULT
		fp *= PODIUM_FOOTPRINT_MULT
		fp = min(fp, lot_size)

	# Create mesh
	var mesh_inst: MeshInstance3D = MeshInstance3D.new()
	var box: BoxMesh = BoxMesh.new()
	box.size = Vector3(fp, height, fp)
	mesh_inst.mesh = box

	# Position: centre of footprint, raised so base sits on y=0.
	var world_pos: Vector3 = lot_origin + Vector3(
		lot_size * 0.5 + offset_x,
		height * 0.5,
		lot_size * 0.5 + offset_z
	)
	mesh_inst.position = world_pos

	# Apply neon shader with per-building colour variation.
	_apply_building_material(mesh_inst)

	add_child(mesh_inst)
	_buildings.append({"node": mesh_inst, "world_pos": world_pos})

	# Track tall buildings as sky-bridge candidates.
	if height >= sky_bridge_min_height:
		tall_rooftops.append({
			"pos": Vector3(world_pos.x, height, world_pos.z),
			"height": height
		})

	# Small chance to add a rooftop antenna mast.
	if _rng.randf() < 0.25:
		_add_rooftop_antenna(world_pos, height, fp)


func _apply_building_material(mesh_inst: MeshInstance3D) -> void:
	if _building_shader == null:
		var mat: StandardMaterial3D = StandardMaterial3D.new()
		mat.albedo_color = Color(_rng.randf_range(0.01, 0.05),
		                         _rng.randf_range(0.01, 0.05),
		                         _rng.randf_range(0.03, 0.08))
		mat.metallic = 0.8
		mat.roughness = 0.2
		mat.emission_enabled = true
		mat.emission = Color(_rng.randf(), 0.0, _rng.randf()) * 4.0
		mesh_inst.material_override = mat
		return

	var mat: ShaderMaterial = _building_shader.duplicate() as ShaderMaterial

	var palette_idx: int = _rng.randi() % NEON_PALETTE.size()
	var palette: Array = NEON_PALETTE[palette_idx]
	# Randomly swap edge/secondary colour.
	var edge_col: Color = palette[0] if _rng.randf() > 0.5 else palette[1]

	mat.set_shader_parameter("edge_color", Vector4(edge_col.r, edge_col.g, edge_col.b, 1.0))
	mat.set_shader_parameter("grid_size", _rng.randf_range(1.5, 3.5))
	mat.set_shader_parameter("edge_thickness", _rng.randf_range(0.04, 0.12))
	mat.set_shader_parameter("emission_str", _rng.randf_range(4.0, 14.0))

	mesh_inst.material_override = mat


func _add_rooftop_antenna(building_pos: Vector3, building_height: float, fp: float) -> void:
	var antenna: MeshInstance3D = MeshInstance3D.new()
	var cyl: CylinderMesh = CylinderMesh.new()
	var mast_h: float = _rng.randf_range(3.0, 12.0)
	cyl.top_radius = 0.1
	cyl.bottom_radius = 0.15
	cyl.height = mast_h
	antenna.mesh = cyl

	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(0.15, 0.15, 0.2)
	mat.metallic = 0.9
	mat.roughness = 0.1
	antenna.material_override = mat

	antenna.position = Vector3(
		building_pos.x + _rng.randf_range(-fp * 0.3, fp * 0.3),
		building_height + mast_h * 0.5,
		building_pos.z + _rng.randf_range(-fp * 0.3, fp * 0.3)
	)
	add_child(antenna)

	# Tiny blinking light at the tip.
	var tip_light: OmniLight3D = OmniLight3D.new()
	tip_light.light_color = Color(1.0, 0.1, 0.1)
	tip_light.light_energy = 1.5
	tip_light.omni_range = 8.0
	tip_light.position = Vector3(antenna.position.x, building_height + mast_h + 0.2, antenna.position.z)
	add_child(tip_light)

	# Animate the blink via a repeating tween.
	var tween: Tween = create_tween().set_loops()
	tween.tween_property(tip_light, "light_energy", 0.0, 0.1)
	tween.tween_interval(_rng.randf_range(0.8, 2.5))
	tween.tween_property(tip_light, "light_energy", 1.5, 0.1)
	tween.tween_interval(0.1)


# ── Sky-Bridges ──────────────────────────────────────────────────────────────

func _generate_sky_bridges(tall_rooftops: Array) -> void:
	if tall_rooftops.is_empty():
		return

	var spawned: int = 0
	var attempts: int = 0
	var max_attempts: int = sky_bridge_count * 6

	while spawned < sky_bridge_count and attempts < max_attempts:
		attempts += 1

		# Pick two random tall rooftops.
		var idx_a: int = _rng.randi() % tall_rooftops.size()
		var idx_b: int = _rng.randi() % tall_rooftops.size()
		if idx_a == idx_b:
			continue

		var a: Dictionary = tall_rooftops[idx_a]
		var b: Dictionary = tall_rooftops[idx_b]

		var horiz_dist: float = Vector2(a.pos.x, a.pos.z).distance_to(Vector2(b.pos.x, b.pos.z))

		# Only connect buildings that are close enough and roughly similar in height.
		if horiz_dist < 10.0 or horiz_dist > 80.0:
			continue
		if abs(a.height - b.height) > 30.0:
			continue

		_spawn_sky_bridge(a.pos, b.pos)
		spawned += 1

	print("[CityGenerator] Sky-bridges placed: %d" % spawned)


func _spawn_sky_bridge(from: Vector3, to: Vector3) -> void:
	# The bridge is a thin box aligned between the two points.
	var mid: Vector3 = (from + to) * 0.5
	var diff: Vector3 = to - from
	var length: float = diff.length()

	var bridge_w: float = _rng.randf_range(1.5, 3.5)
	var bridge_h: float = _rng.randf_range(0.6, 1.5)
	# Place the bridge slightly below the rooftop so it looks attached.
	var bridge_y: float = mid.y - _rng.randf_range(2.0, 6.0)

	var mesh_inst: MeshInstance3D = MeshInstance3D.new()
	var box: BoxMesh = BoxMesh.new()
	# length maps to the Z-axis (local forward); after rotation.y the Z-axis
	# aligns with the diff vector, so the bridge spans correctly between buildings.
	box.size = Vector3(bridge_w, bridge_h, length)
	mesh_inst.mesh = box

	mesh_inst.position = Vector3(mid.x, bridge_y, mid.z)
	# Rotate to align with the direction vector.
	mesh_inst.rotation.y = atan2(diff.x, diff.z)

	# Neon glowing bridge material.
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	var col_idx: int = _rng.randi() % NEON_LIGHT_COLORS.size()
	var neon: Color = NEON_LIGHT_COLORS[col_idx]
	mat.albedo_color = neon * 0.15
	mat.metallic = 0.9
	mat.roughness = 0.1
	mat.emission_enabled = true
	mat.emission = neon
	mat.emission_energy_multiplier = 2.0
	mesh_inst.material_override = mat

	add_child(mesh_inst)

	# Support pillars at each end (only for medium-distance bridges).
	if length > 25.0:
		_add_bridge_pillar(from, bridge_y, neon)
		_add_bridge_pillar(to, bridge_y, neon)


func _add_bridge_pillar(roof_pos: Vector3, bridge_y: float, neon: Color) -> void:
	var pillar_h: float = roof_pos.y - bridge_y
	if pillar_h < 1.0:
		return

	var pillar: MeshInstance3D = MeshInstance3D.new()
	var cyl: CylinderMesh = CylinderMesh.new()
	cyl.top_radius = 0.2
	cyl.bottom_radius = 0.2
	cyl.height = pillar_h
	pillar.mesh = cyl

	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = neon * 0.1
	mat.emission_enabled = true
	mat.emission = neon
	mat.emission_energy_multiplier = 1.5
	pillar.material_override = mat

	pillar.position = Vector3(roof_pos.x, bridge_y + pillar_h * 0.5, roof_pos.z)
	add_child(pillar)


# ── Street Lights ────────────────────────────────────────────────────────────

func _scatter_street_lights() -> void:
	var stride: float = block_size + road_width
	var half_extent: float = (city_radius * stride) * 0.9

	for _i in range(street_light_count):
		var x: float = _rng.randf_range(-half_extent, half_extent)
		var z: float = _rng.randf_range(-half_extent, half_extent)

		# Snap to road-side positions (between blocks on either axis).
		# A simple approximation: snap x or z to a block edge.
		if _rng.randf() > 0.5:
			var snapped_x: float = round(x / stride) * stride
			x = snapped_x + block_size * 0.5 * sign(x - snapped_x)
		else:
			var snapped_z: float = round(z / stride) * stride
			z = snapped_z + block_size * 0.5 * sign(z - snapped_z)

		var col_idx: int = _rng.randi() % NEON_LIGHT_COLORS.size()
		var neon: Color = NEON_LIGHT_COLORS[col_idx]

		var light: OmniLight3D = OmniLight3D.new()
		light.light_color = neon
		light.light_energy = _rng.randf_range(1.5, 3.5)
		light.omni_range = _rng.randf_range(12.0, 28.0)
		light.position = Vector3(x, _rng.randf_range(4.0, 8.0), z)
		add_child(light)

		# Slight flicker for atmospheric effect.
		if _rng.randf() < 0.3:
			_add_flicker(light)


func _add_flicker(light: OmniLight3D) -> void:
	var base_energy: float = light.light_energy
	var tween: Tween = create_tween().set_loops()
	tween.tween_property(light, "light_energy", base_energy * _rng.randf_range(0.6, 0.9), _rng.randf_range(0.05, 0.15))
	tween.tween_property(light, "light_energy", base_energy, _rng.randf_range(0.05, 0.2))
	tween.tween_interval(_rng.randf_range(0.5, 3.0))


# ── LOD System ───────────────────────────────────────────────────────────────

func _update_lod() -> void:
	if _camera == null:
		_camera = get_viewport().get_camera_3d()
		if _camera == null:
			return

	var cam_pos: Vector3 = _camera.global_position
	var cull_sq: float = lod_cull_distance * lod_cull_distance

	for entry in _buildings:
		var node: MeshInstance3D = entry["node"]
		if not is_instance_valid(node):
			continue
		var dist_sq: float = cam_pos.distance_squared_to(entry["world_pos"])
		node.visible = dist_sq <= cull_sq
