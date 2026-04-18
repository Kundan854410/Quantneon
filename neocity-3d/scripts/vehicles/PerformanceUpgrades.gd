## PerformanceUpgrades
## -----------------------------------------------------------------------------
## Owns the tuning progression for a single player vehicle.
##
## Categories:
##   * engine      — top speed and acceleration
##   * brakes      — stopping distance
##   * suspension  — handling / grip
##   * nitro       — boost duration & thrust
##
## Tiers (per category):
##   * stock → sport → race → elite
##
## Visual per-tier effects (rolled up into a "highest tier across categories"):
##   * sport → body kit attachments at configured mount points
##   * race  → adds a rear wing
##   * elite → glowing emissive aura around the chassis
##
## The class optionally talks to a VehicleCustomizer instance (if provided) to
## respect aerodynamic contributions from the current spoiler when computing the
## final performance profile. It also exposes a spider-chart data builder
## suitable for direct consumption by a Control-based renderer.
extends Node
class_name PerformanceUpgrades

## -----------------------------------------------------------------------------
## Signals
## -----------------------------------------------------------------------------
signal upgrade_purchased(category: String, tier: String, cost: int)
signal upgrade_installed(category: String, tier: String)
signal upgrade_refunded(category: String, tier: String, refund: int)
signal stats_recomputed(stats: Dictionary)
signal insufficient_funds(required: int, balance: int)

## -----------------------------------------------------------------------------
## Constants
## -----------------------------------------------------------------------------
const TIER_STOCK: String = "stock"
const TIER_SPORT: String = "sport"
const TIER_RACE: String = "race"
const TIER_ELITE: String = "elite"

const TIER_ORDER: Array[String] = [TIER_STOCK, TIER_SPORT, TIER_RACE, TIER_ELITE]

const CAT_ENGINE: String = "engine"
const CAT_BRAKES: String = "brakes"
const CAT_SUSPENSION: String = "suspension"
const CAT_NITRO: String = "nitro"

const ALL_CATEGORIES: Array[String] = [CAT_ENGINE, CAT_BRAKES, CAT_SUSPENSION, CAT_NITRO]

## Cost table (Quant tokens). Stock is always free and cannot be purchased — it
## is the default. Higher tiers require the previous tier to be installed first.
const TIER_COSTS: Dictionary = {
	CAT_ENGINE: {
		TIER_STOCK: 0,
		TIER_SPORT: 1200,
		TIER_RACE:  4200,
		TIER_ELITE: 11800,
	},
	CAT_BRAKES: {
		TIER_STOCK: 0,
		TIER_SPORT: 800,
		TIER_RACE:  2600,
		TIER_ELITE: 7400,
	},
	CAT_SUSPENSION: {
		TIER_STOCK: 0,
		TIER_SPORT: 950,
		TIER_RACE:  2950,
		TIER_ELITE: 8100,
	},
	CAT_NITRO: {
		TIER_STOCK: 0,
		TIER_SPORT: 1000,
		TIER_RACE:  3400,
		TIER_ELITE: 9500,
	},
}

## Per-tier bonus multipliers (fraction of stock). These correspond to the
## ranges specified in the design brief:
##   engine:     speed +10–50%
##   brakes:     stopping distance -10–40% (represented as brake power bonus)
##   suspension: handling +10–30%
##   nitro:      boost duration +20–100%, thrust +15–90%
const TIER_BONUSES: Dictionary = {
	CAT_ENGINE: {
		TIER_STOCK: 0.00,
		TIER_SPORT: 0.12,
		TIER_RACE:  0.28,
		TIER_ELITE: 0.50,
	},
	CAT_BRAKES: {
		TIER_STOCK: 0.00,
		TIER_SPORT: 0.12,
		TIER_RACE:  0.26,
		TIER_ELITE: 0.40,
	},
	CAT_SUSPENSION: {
		TIER_STOCK: 0.00,
		TIER_SPORT: 0.10,
		TIER_RACE:  0.20,
		TIER_ELITE: 0.30,
	},
	CAT_NITRO: {
		TIER_STOCK: 0.00,
		TIER_SPORT: 0.24,
		TIER_RACE:  0.55,
		TIER_ELITE: 1.00,
	},
}

## Nitro also has a thrust component used by the vehicle controller.
const NITRO_THRUST_BONUS: Dictionary = {
	TIER_STOCK: 0.00,
	TIER_SPORT: 0.15,
	TIER_RACE:  0.45,
	TIER_ELITE: 0.90,
}

## Refund fraction when a tier is removed.
const REFUND_FRACTION: float = 0.6

## Stock baselines (pre-tuning) used by the stats builder. These values are
## expressed in user-facing units and are purely for the UI — the vehicle
## controller applies the multipliers separately to its own physics values.
const BASE_STATS: Dictionary = {
	"top_speed_kmh": 210.0,
	"acceleration_0_100_s": 5.8,
	"braking_distance_100_0_m": 40.0,
	"handling_index": 0.55,   # 0..1
	"nitro_duration_s": 3.0,
	"nitro_thrust_g": 1.6,
}

## -----------------------------------------------------------------------------
## Exported fields
## -----------------------------------------------------------------------------
@export var profile_user_id: String = "local_user"
@export_node_path("Node") var customizer_path: NodePath
@export_node_path("Node3D") var vehicle_path: NodePath

## -----------------------------------------------------------------------------
## Runtime state
## -----------------------------------------------------------------------------
var current_tiers: Dictionary = {
	CAT_ENGINE: TIER_STOCK,
	CAT_BRAKES: TIER_STOCK,
	CAT_SUSPENSION: TIER_STOCK,
	CAT_NITRO: TIER_STOCK,
}

var token_balance: int = 5000
var _customizer: Node = null
var _vehicle: Node3D = null

var _sport_kit_instance: Node3D = null
var _race_wing_instance: Node3D = null
var _elite_aura_instance: Node3D = null

## -----------------------------------------------------------------------------
## Lifecycle
## -----------------------------------------------------------------------------
func _ready() -> void:
	if customizer_path != NodePath(""):
		_customizer = get_node_or_null(customizer_path)
	if vehicle_path != NodePath(""):
		_vehicle = get_node_or_null(vehicle_path)
	if _vehicle == null:
		var p = get_parent()
		if p is Node3D:
			_vehicle = p
	_refresh_visual_tier()
	emit_signal("stats_recomputed", compute_effective_stats())

## -----------------------------------------------------------------------------
## Token balance
## -----------------------------------------------------------------------------
func set_token_balance(value: int) -> void:
	token_balance = max(0, value)

func add_tokens(amount: int) -> void:
	token_balance = max(0, token_balance + amount)

## -----------------------------------------------------------------------------
## Tier helpers
## -----------------------------------------------------------------------------
static func tier_index(tier: String) -> int:
	return TIER_ORDER.find(tier)

static func next_tier(tier: String) -> String:
	var idx := tier_index(tier)
	if idx < 0:
		return TIER_STOCK
	if idx >= TIER_ORDER.size() - 1:
		return ""
	return TIER_ORDER[idx + 1]

static func previous_tier(tier: String) -> String:
	var idx := tier_index(tier)
	if idx <= 0:
		return ""
	return TIER_ORDER[idx - 1]

func current_tier_of(category: String) -> String:
	return String(current_tiers.get(category, TIER_STOCK))

func cost_for_next_tier(category: String) -> int:
	var nxt := next_tier(current_tier_of(category))
	if nxt == "":
		return 0
	return int(TIER_COSTS.get(category, {}).get(nxt, 0))

func total_invested_tokens() -> int:
	var sum := 0
	for cat in ALL_CATEGORIES:
		var t = current_tier_of(cat)
		var idx := tier_index(t)
		for i in range(1, idx + 1):
			sum += int(TIER_COSTS.get(cat, {}).get(TIER_ORDER[i], 0))
	return sum

## -----------------------------------------------------------------------------
## Purchase / install / refund
## -----------------------------------------------------------------------------
func can_purchase_next(category: String) -> bool:
	if not category in ALL_CATEGORIES:
		return false
	var nxt := next_tier(current_tier_of(category))
	if nxt == "":
		return false
	return token_balance >= int(TIER_COSTS.get(category, {}).get(nxt, 0))

func purchase_next_tier(category: String) -> bool:
	if not category in ALL_CATEGORIES:
		push_warning("[PerformanceUpgrades] Unknown category: " + category)
		return false
	var nxt := next_tier(current_tier_of(category))
	if nxt == "":
		return false
	var cost := int(TIER_COSTS.get(category, {}).get(nxt, 0))
	if token_balance < cost:
		emit_signal("insufficient_funds", cost, token_balance)
		return false
	token_balance -= cost
	current_tiers[category] = nxt
	emit_signal("upgrade_purchased", category, nxt, cost)
	emit_signal("upgrade_installed", category, nxt)
	_refresh_visual_tier()
	emit_signal("stats_recomputed", compute_effective_stats())
	return true

func refund_current_tier(category: String) -> bool:
	if not category in ALL_CATEGORIES:
		return false
	var cur := current_tier_of(category)
	var prev := previous_tier(cur)
	if prev == "":
		return false
	var cost := int(TIER_COSTS.get(category, {}).get(cur, 0))
	var refund := int(round(float(cost) * REFUND_FRACTION))
	token_balance += refund
	current_tiers[category] = prev
	emit_signal("upgrade_refunded", category, cur, refund)
	_refresh_visual_tier()
	emit_signal("stats_recomputed", compute_effective_stats())
	return true

func install_tier(category: String, tier: String, charge_tokens: bool = true) -> bool:
	# Admin / shop-driven install path. Sets the category directly (respecting
	# ordering). If charge_tokens is true, the *sum* of tier costs up to and
	# including the target tier is deducted from the balance.
	if not category in ALL_CATEGORIES:
		return false
	if not tier in TIER_ORDER:
		return false
	var target_idx := tier_index(tier)
	var current_idx := tier_index(current_tier_of(category))
	if target_idx <= current_idx:
		return false
	var cumulative_cost := 0
	for i in range(current_idx + 1, target_idx + 1):
		cumulative_cost += int(TIER_COSTS.get(category, {}).get(TIER_ORDER[i], 0))
	if charge_tokens:
		if token_balance < cumulative_cost:
			emit_signal("insufficient_funds", cumulative_cost, token_balance)
			return false
		token_balance -= cumulative_cost
	current_tiers[category] = tier
	emit_signal("upgrade_purchased", category, tier, cumulative_cost)
	emit_signal("upgrade_installed", category, tier)
	_refresh_visual_tier()
	emit_signal("stats_recomputed", compute_effective_stats())
	return true

func reset_all() -> void:
	# Full rollback to stock across every category; tokens are refunded at the
	# standard refund fraction.
	var total_refund := 0
	for cat in ALL_CATEGORIES:
		var idx := tier_index(current_tier_of(cat))
		for i in range(1, idx + 1):
			total_refund += int(round(float(TIER_COSTS.get(cat, {}).get(TIER_ORDER[i], 0)) * REFUND_FRACTION))
		current_tiers[cat] = TIER_STOCK
	token_balance += total_refund
	_refresh_visual_tier()
	emit_signal("stats_recomputed", compute_effective_stats())

## -----------------------------------------------------------------------------
## Highest tier across categories (drives visual effects)
## -----------------------------------------------------------------------------
func highest_installed_tier() -> String:
	var highest_idx := 0
	for cat in ALL_CATEGORIES:
		var idx := tier_index(current_tier_of(cat))
		if idx > highest_idx:
			highest_idx = idx
	return TIER_ORDER[highest_idx]

func tier_count_at_or_above(tier: String) -> int:
	var target_idx := tier_index(tier)
	var count := 0
	for cat in ALL_CATEGORIES:
		if tier_index(current_tier_of(cat)) >= target_idx:
			count += 1
	return count

## -----------------------------------------------------------------------------
## Visual upgrades — body kit, wing, aura
## -----------------------------------------------------------------------------
func _refresh_visual_tier() -> void:
	_apply_sport_kit(highest_installed_tier() != TIER_STOCK)
	_apply_race_wing(tier_index(highest_installed_tier()) >= tier_index(TIER_RACE))
	_apply_elite_aura(highest_installed_tier() == TIER_ELITE)

func _apply_sport_kit(enabled: bool) -> void:
	if _vehicle == null:
		return
	var mount = _vehicle.get_node_or_null("BodyKitMount")
	if mount == null:
		mount = _vehicle
	if enabled:
		if _sport_kit_instance == null or not is_instance_valid(_sport_kit_instance):
			_sport_kit_instance = Node3D.new()
			_sport_kit_instance.name = "SportBodyKit"
			# Front splitter
			var splitter := MeshInstance3D.new()
			var sm := BoxMesh.new()
			sm.size = Vector3(1.9, 0.06, 0.35)
			splitter.mesh = sm
			splitter.position = Vector3(0, 0.05, 1.6)
			_sport_kit_instance.add_child(splitter)
			# Side skirts
			for side in [-1.0, 1.0]:
				var skirt := MeshInstance3D.new()
				var bm := BoxMesh.new()
				bm.size = Vector3(0.08, 0.12, 2.5)
				skirt.mesh = bm
				skirt.position = Vector3(side * 0.98, 0.18, 0.0)
				_sport_kit_instance.add_child(skirt)
			# Rear diffuser
			var diff := MeshInstance3D.new()
			var dm := BoxMesh.new()
			dm.size = Vector3(1.7, 0.08, 0.45)
			diff.mesh = dm
			diff.position = Vector3(0, 0.1, -1.6)
			_sport_kit_instance.add_child(diff)
			_tint_children(_sport_kit_instance, Color(0.08, 0.08, 0.08), 0.6, 0.2)
			mount.add_child(_sport_kit_instance)
	else:
		if _sport_kit_instance != null and is_instance_valid(_sport_kit_instance):
			_sport_kit_instance.queue_free()
			_sport_kit_instance = null

func _apply_race_wing(enabled: bool) -> void:
	if _vehicle == null:
		return
	if enabled:
		if _race_wing_instance == null or not is_instance_valid(_race_wing_instance):
			_race_wing_instance = Node3D.new()
			_race_wing_instance.name = "RaceWing"
			# Two vertical struts
			for side in [-1.0, 1.0]:
				var strut := MeshInstance3D.new()
				var cm := CylinderMesh.new()
				cm.top_radius = 0.025
				cm.bottom_radius = 0.025
				cm.height = 0.35
				strut.mesh = cm
				strut.position = Vector3(side * 0.65, 1.25, -1.4)
				_race_wing_instance.add_child(strut)
			# Wing blade
			var blade := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3(1.8, 0.08, 0.45)
			blade.mesh = bm
			blade.position = Vector3(0, 1.45, -1.4)
			_race_wing_instance.add_child(blade)
			_tint_children(_race_wing_instance, Color(0.05, 0.05, 0.05), 0.8, 0.15)
			_vehicle.add_child(_race_wing_instance)
	else:
		if _race_wing_instance != null and is_instance_valid(_race_wing_instance):
			_race_wing_instance.queue_free()
			_race_wing_instance = null

func _apply_elite_aura(enabled: bool) -> void:
	if _vehicle == null:
		return
	if enabled:
		if _elite_aura_instance == null or not is_instance_valid(_elite_aura_instance):
			_elite_aura_instance = Node3D.new()
			_elite_aura_instance.name = "EliteAura"
			var omni := OmniLight3D.new()
			omni.light_color = Color(1.0, 0.3, 1.0)
			omni.light_energy = 3.2
			omni.omni_range = 4.5
			omni.position = Vector3(0, 0.3, 0)
			_elite_aura_instance.add_child(omni)
			# A subtle torus shell with emissive shader as visible aura ring.
			var ring := MeshInstance3D.new()
			var tm := TorusMesh.new()
			tm.inner_radius = 1.6
			tm.outer_radius = 1.8
			ring.mesh = tm
			var aura_mat := StandardMaterial3D.new()
			aura_mat.albedo_color = Color(1.0, 0.3, 1.0, 0.35)
			aura_mat.emission_enabled = true
			aura_mat.emission = Color(1.0, 0.3, 1.0)
			aura_mat.emission_energy_multiplier = 2.8
			aura_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			ring.material_override = aura_mat
			ring.rotation = Vector3(PI * 0.5, 0, 0)
			ring.position = Vector3(0, 0.05, 0)
			_elite_aura_instance.add_child(ring)
			_vehicle.add_child(_elite_aura_instance)
	else:
		if _elite_aura_instance != null and is_instance_valid(_elite_aura_instance):
			_elite_aura_instance.queue_free()
			_elite_aura_instance = null

func _tint_children(root: Node, color: Color, metallic: float, roughness: float) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.metallic = metallic
	mat.roughness = roughness
	for child in root.get_children():
		if child is MeshInstance3D:
			child.material_override = mat

## -----------------------------------------------------------------------------
## Effective stats — spider chart data
## -----------------------------------------------------------------------------
func compute_effective_stats() -> Dictionary:
	var eng_bonus: float = _bonus_of(CAT_ENGINE)
	var brk_bonus: float = _bonus_of(CAT_BRAKES)
	var sus_bonus: float = _bonus_of(CAT_SUSPENSION)
	var nit_bonus: float = _bonus_of(CAT_NITRO)
	var nit_thrust_bonus: float = float(NITRO_THRUST_BONUS.get(current_tier_of(CAT_NITRO), 0.0))

	var customizer_downforce: float = 0.0
	var customizer_drag: float = 0.0
	if _customizer and _customizer.has_method("get_spoiler_downforce"):
		customizer_downforce = float(_customizer.call("get_spoiler_downforce"))
	if _customizer and _customizer.has_method("get_spoiler_drag"):
		customizer_drag = float(_customizer.call("get_spoiler_drag"))

	# Engine bonus reduces by drag contribution; suspension boosted by downforce.
	var effective_engine_bonus: float = max(0.0, eng_bonus - customizer_drag * 0.4)
	var effective_handling_bonus: float = sus_bonus + customizer_downforce * 0.2

	var top_speed: float = BASE_STATS.top_speed_kmh * (1.0 + effective_engine_bonus)
	var accel: float = BASE_STATS.acceleration_0_100_s / (1.0 + effective_engine_bonus * 0.85)
	var brake_dist: float = BASE_STATS.braking_distance_100_0_m * (1.0 - brk_bonus)
	var handling: float = clamp(BASE_STATS.handling_index * (1.0 + effective_handling_bonus), 0.0, 1.0)
	var nitro_dur: float = BASE_STATS.nitro_duration_s * (1.0 + nit_bonus)
	var nitro_thrust: float = BASE_STATS.nitro_thrust_g * (1.0 + nit_thrust_bonus)

	return {
		"top_speed_kmh": top_speed,
		"acceleration_0_100_s": accel,
		"braking_distance_100_0_m": brake_dist,
		"handling_index": handling,
		"nitro_duration_s": nitro_dur,
		"nitro_thrust_g": nitro_thrust,
		"tiers": current_tiers.duplicate(true),
		"highest_tier": highest_installed_tier(),
	}

func _bonus_of(category: String) -> float:
	return float(TIER_BONUSES.get(category, {}).get(current_tier_of(category), 0.0))

## Returns a normalized 0..1 array keyed in the canonical spider-chart order:
##   [speed, handling, braking, acceleration, nitro]
func spider_chart_points() -> Array:
	var s := compute_effective_stats()
	# Normalize each axis against a reasonable "elite max" ceiling so the chart
	# visually fills as the player upgrades.
	var speed_norm: float = clamp((s.top_speed_kmh - 180.0) / (380.0 - 180.0), 0.0, 1.0)
	var handling_norm: float = clamp(s.handling_index, 0.0, 1.0)
	# Lower brake distance is better — invert.
	var brake_norm: float = clamp(1.0 - (s.braking_distance_100_0_m / BASE_STATS.braking_distance_100_0_m) + 0.25, 0.0, 1.0)
	# Lower accel time is better — invert.
	var accel_norm: float = clamp(1.0 - (s.acceleration_0_100_s / BASE_STATS.acceleration_0_100_s) + 0.25, 0.0, 1.0)
	var nitro_norm: float = clamp((s.nitro_duration_s - 2.5) / (7.5 - 2.5), 0.0, 1.0)
	return [speed_norm, handling_norm, brake_norm, accel_norm, nitro_norm]

func spider_chart_labels() -> Array:
	return ["Speed", "Handling", "Braking", "Acceleration", "Nitro"]

## Builds 2D polygon points for a regular pentagon spider chart centered at
## origin with the given radius. The polygon's vertices are scaled by
## spider_chart_points() so it renders directly with Polygon2D or lines.
func build_spider_polygon(center: Vector2, radius: float) -> PackedVector2Array:
	var points := spider_chart_points()
	var n := points.size()
	var out := PackedVector2Array()
	out.resize(n)
	for i in range(n):
		var angle: float = -PI * 0.5 + TAU * float(i) / float(n)
		var r: float = radius * float(points[i])
		out[i] = center + Vector2(cos(angle), sin(angle)) * r
	return out

func build_spider_axis_polygon(center: Vector2, radius: float) -> PackedVector2Array:
	var n := 5
	var out := PackedVector2Array()
	out.resize(n)
	for i in range(n):
		var angle: float = -PI * 0.5 + TAU * float(i) / float(n)
		out[i] = center + Vector2(cos(angle), sin(angle)) * radius
	return out

## -----------------------------------------------------------------------------
## Serialization
## -----------------------------------------------------------------------------
func export_state() -> Dictionary:
	return {
		"version": 1,
		"owner": profile_user_id,
		"tiers": current_tiers.duplicate(true),
		"balance": token_balance,
	}

func import_state(state: Dictionary) -> bool:
	if state.is_empty():
		return false
	var t: Dictionary = state.get("tiers", {})
	for cat in ALL_CATEGORIES:
		if t.has(cat) and TIER_ORDER.has(t[cat]):
			current_tiers[cat] = t[cat]
	if state.has("balance"):
		token_balance = int(state["balance"])
	_refresh_visual_tier()
	emit_signal("stats_recomputed", compute_effective_stats())
	return true

## -----------------------------------------------------------------------------
## Convenience queries
## -----------------------------------------------------------------------------
func describe() -> String:
	var lines := PackedStringArray()
	for cat in ALL_CATEGORIES:
		lines.append("%s: %s" % [cat, current_tier_of(cat)])
	lines.append("Balance: %d QNT" % token_balance)
	return "\n".join(lines)

func is_fully_elite() -> bool:
	for cat in ALL_CATEGORIES:
		if current_tier_of(cat) != TIER_ELITE:
			return false
	return true
