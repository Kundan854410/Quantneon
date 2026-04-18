## VehicleCustomizer
## -----------------------------------------------------------------------------
## Runtime customization stack for Neo City player vehicles.
##
## Responsibilities:
##   * Body paint with ShaderMaterial (metallic, matte, chrome, pearlescent)
##   * Decal application (50+ templates) projected onto body via Decal nodes
##   * Wheels (20 styles), spoilers (10 styles), exhausts (5 styles)
##   * Underglow lighting (HSV/RGB neon) with flicker/pulse patterns
##   * Save / load customization configurations to the player profile
##   * Snapshot exports to the marketplace and garage preview
##
## The customizer operates on a VehicleBody3D (or any Node3D) that exposes the
## following optional child paths:
##   BodyMesh            : MeshInstance3D   (main body)
##   WheelMesh_{0..3}    : MeshInstance3D   (four corners)
##   SpoilerMount        : Node3D           (attachment anchor)
##   ExhaustMount        : Node3D           (attachment anchor)
##   UnderglowAnchor     : Node3D           (under chassis)
##
## Any missing child is tolerated; the customizer logs a warning and skips that
## slot. This keeps the class usable inside editor previews and headless tests.
extends Node
class_name VehicleCustomizer

## -----------------------------------------------------------------------------
## Signals
## -----------------------------------------------------------------------------
signal paint_changed(color: Color, finish: String)
signal decal_applied(decal_id: String, slot: int)
signal decal_removed(slot: int)
signal wheels_changed(wheel_id: String)
signal spoiler_changed(spoiler_id: String)
signal exhaust_changed(exhaust_id: String)
signal underglow_changed(color: Color, pattern: String)
signal configuration_loaded(config_name: String)
signal configuration_saved(config_name: String)
signal snapshot_captured(image: Image)

## -----------------------------------------------------------------------------
## Constants — Finishes
## -----------------------------------------------------------------------------
const FINISH_METALLIC: String = "metallic"
const FINISH_MATTE: String = "matte"
const FINISH_CHROME: String = "chrome"
const FINISH_PEARLESCENT: String = "pearlescent"

const ALL_FINISHES: Array[String] = [
	FINISH_METALLIC,
	FINISH_MATTE,
	FINISH_CHROME,
	FINISH_PEARLESCENT,
]

## -----------------------------------------------------------------------------
## Constants — Decal Catalogue (50+ templates)
## -----------------------------------------------------------------------------
## Decals are keyed by ID. Each entry carries a human-readable name, a category,
## a rarity tier, a price in Quant tokens, and a texture path that callers may
## resolve via ResourceLoader.
const DECAL_CATALOGUE: Dictionary = {
	"flame_classic":       {"name": "Classic Flame",         "category": "Flames",    "rarity": "common",    "price": 150,  "path": "res://materials/decals/flame_classic.png"},
	"flame_blue":          {"name": "Blue Inferno",          "category": "Flames",    "rarity": "uncommon",  "price": 300,  "path": "res://materials/decals/flame_blue.png"},
	"flame_cyber":         {"name": "Cyber Plasma",          "category": "Flames",    "rarity": "rare",      "price": 750,  "path": "res://materials/decals/flame_cyber.png"},
	"flame_skull":         {"name": "Skull & Flame",         "category": "Flames",    "rarity": "uncommon",  "price": 450,  "path": "res://materials/decals/flame_skull.png"},
	"stripe_racing":       {"name": "Racing Stripes",        "category": "Stripes",   "rarity": "common",    "price": 100,  "path": "res://materials/decals/stripe_racing.png"},
	"stripe_dual":         {"name": "Dual Stripe",           "category": "Stripes",   "rarity": "common",    "price": 120,  "path": "res://materials/decals/stripe_dual.png"},
	"stripe_ghost":        {"name": "Ghost Stripe",          "category": "Stripes",   "rarity": "uncommon",  "price": 250,  "path": "res://materials/decals/stripe_ghost.png"},
	"stripe_lightning":    {"name": "Lightning Stripe",      "category": "Stripes",   "rarity": "rare",      "price": 600,  "path": "res://materials/decals/stripe_lightning.png"},
	"tribal_left":         {"name": "Tribal Left Side",      "category": "Tribal",    "rarity": "common",    "price": 180,  "path": "res://materials/decals/tribal_left.png"},
	"tribal_right":        {"name": "Tribal Right Side",     "category": "Tribal",    "rarity": "common",    "price": 180,  "path": "res://materials/decals/tribal_right.png"},
	"tribal_wing":         {"name": "Tribal Wings",          "category": "Tribal",    "rarity": "uncommon",  "price": 320,  "path": "res://materials/decals/tribal_wing.png"},
	"tribal_dragon":       {"name": "Tribal Dragon",         "category": "Tribal",    "rarity": "rare",      "price": 800,  "path": "res://materials/decals/tribal_dragon.png"},
	"faction_reapers":     {"name": "Reapers Crest",         "category": "Factions",  "rarity": "rare",      "price": 900,  "path": "res://materials/decals/faction_reapers.png"},
	"faction_ghosts":      {"name": "Ghosts Insignia",       "category": "Factions",  "rarity": "rare",      "price": 900,  "path": "res://materials/decals/faction_ghosts.png"},
	"faction_syndicate":   {"name": "Syndicate Seal",        "category": "Factions",  "rarity": "rare",      "price": 900,  "path": "res://materials/decals/faction_syndicate.png"},
	"faction_neonkings":   {"name": "Neon Kings Crown",      "category": "Factions",  "rarity": "epic",      "price": 1500, "path": "res://materials/decals/faction_neonkings.png"},
	"kanji_speed":         {"name": "Kanji — Speed",         "category": "Kanji",     "rarity": "common",    "price": 140,  "path": "res://materials/decals/kanji_speed.png"},
	"kanji_power":         {"name": "Kanji — Power",         "category": "Kanji",     "rarity": "common",    "price": 140,  "path": "res://materials/decals/kanji_power.png"},
	"kanji_dragon":        {"name": "Kanji — Dragon",        "category": "Kanji",     "rarity": "uncommon",  "price": 280,  "path": "res://materials/decals/kanji_dragon.png"},
	"kanji_thunder":       {"name": "Kanji — Thunder",       "category": "Kanji",     "rarity": "uncommon",  "price": 280,  "path": "res://materials/decals/kanji_thunder.png"},
	"number_00":           {"name": "Race Number 00",        "category": "Numbers",   "rarity": "common",    "price": 80,   "path": "res://materials/decals/number_00.png"},
	"number_07":           {"name": "Race Number 07",        "category": "Numbers",   "rarity": "common",    "price": 80,   "path": "res://materials/decals/number_07.png"},
	"number_13":           {"name": "Race Number 13",        "category": "Numbers",   "rarity": "common",    "price": 80,   "path": "res://materials/decals/number_13.png"},
	"number_42":           {"name": "Race Number 42",        "category": "Numbers",   "rarity": "common",    "price": 80,   "path": "res://materials/decals/number_42.png"},
	"number_69":           {"name": "Race Number 69",        "category": "Numbers",   "rarity": "uncommon",  "price": 160,  "path": "res://materials/decals/number_69.png"},
	"number_99":           {"name": "Race Number 99",        "category": "Numbers",   "rarity": "common",    "price": 80,   "path": "res://materials/decals/number_99.png"},
	"sponsor_quantads":    {"name": "Sponsor — QuantAds",    "category": "Sponsors",  "rarity": "uncommon",  "price": 0,    "path": "res://materials/decals/sponsor_quantads.png"},
	"sponsor_neofuel":     {"name": "Sponsor — NeoFuel",     "category": "Sponsors",  "rarity": "uncommon",  "price": 0,    "path": "res://materials/decals/sponsor_neofuel.png"},
	"sponsor_chromecola":  {"name": "Sponsor — ChromeCola",  "category": "Sponsors",  "rarity": "uncommon",  "price": 0,    "path": "res://materials/decals/sponsor_chromecola.png"},
	"sponsor_nightlife":   {"name": "Sponsor — Nightlife",   "category": "Sponsors",  "rarity": "uncommon",  "price": 0,    "path": "res://materials/decals/sponsor_nightlife.png"},
	"circuit_blue":        {"name": "Circuit Board — Blue",  "category": "Tech",      "rarity": "rare",      "price": 700,  "path": "res://materials/decals/circuit_blue.png"},
	"circuit_green":       {"name": "Circuit Board — Green", "category": "Tech",      "rarity": "rare",      "price": 700,  "path": "res://materials/decals/circuit_green.png"},
	"glitch_art":          {"name": "Glitch Art",            "category": "Tech",      "rarity": "epic",      "price": 1400, "path": "res://materials/decals/glitch_art.png"},
	"hologram_grid":       {"name": "Hologram Grid",         "category": "Tech",      "rarity": "epic",      "price": 1600, "path": "res://materials/decals/hologram_grid.png"},
	"wireframe":           {"name": "Wireframe",             "category": "Tech",      "rarity": "rare",      "price": 650,  "path": "res://materials/decals/wireframe.png"},
	"graffiti_tag":        {"name": "Graffiti Tag",          "category": "Street",    "rarity": "common",    "price": 120,  "path": "res://materials/decals/graffiti_tag.png"},
	"graffiti_throw":      {"name": "Graffiti Throwie",      "category": "Street",    "rarity": "common",    "price": 150,  "path": "res://materials/decals/graffiti_throw.png"},
	"graffiti_piece":      {"name": "Graffiti Piece",        "category": "Street",    "rarity": "uncommon",  "price": 380,  "path": "res://materials/decals/graffiti_piece.png"},
	"graffiti_wildstyle":  {"name": "Graffiti Wildstyle",    "category": "Street",    "rarity": "rare",      "price": 720,  "path": "res://materials/decals/graffiti_wildstyle.png"},
	"anime_hero":          {"name": "Anime Hero",            "category": "Anime",     "rarity": "rare",      "price": 900,  "path": "res://materials/decals/anime_hero.png"},
	"anime_samurai":       {"name": "Anime Samurai",         "category": "Anime",     "rarity": "rare",      "price": 900,  "path": "res://materials/decals/anime_samurai.png"},
	"anime_mecha":         {"name": "Anime Mecha",           "category": "Anime",     "rarity": "epic",      "price": 1800, "path": "res://materials/decals/anime_mecha.png"},
	"retro_sunset":        {"name": "Retro Sunset",          "category": "Retro",     "rarity": "uncommon",  "price": 340,  "path": "res://materials/decals/retro_sunset.png"},
	"retro_palm":          {"name": "Retro Palm",            "category": "Retro",     "rarity": "uncommon",  "price": 300,  "path": "res://materials/decals/retro_palm.png"},
	"retro_neon_wave":     {"name": "Retro Neon Wave",       "category": "Retro",     "rarity": "rare",      "price": 760,  "path": "res://materials/decals/retro_neon_wave.png"},
	"skull_chrome":        {"name": "Chrome Skull",          "category": "Skulls",    "rarity": "uncommon",  "price": 420,  "path": "res://materials/decals/skull_chrome.png"},
	"skull_cyber":         {"name": "Cyber Skull",           "category": "Skulls",    "rarity": "rare",      "price": 820,  "path": "res://materials/decals/skull_cyber.png"},
	"skull_ghost":         {"name": "Ghost Skull",           "category": "Skulls",    "rarity": "rare",      "price": 860,  "path": "res://materials/decals/skull_ghost.png"},
	"phoenix_rising":      {"name": "Phoenix Rising",        "category": "Mythic",    "rarity": "epic",      "price": 1900, "path": "res://materials/decals/phoenix_rising.png"},
	"dragon_serpent":      {"name": "Dragon Serpent",        "category": "Mythic",    "rarity": "epic",      "price": 1950, "path": "res://materials/decals/dragon_serpent.png"},
	"koi_fish":            {"name": "Koi Fish",              "category": "Mythic",    "rarity": "rare",      "price": 780,  "path": "res://materials/decals/koi_fish.png"},
	"galaxy_spiral":       {"name": "Galaxy Spiral",         "category": "Cosmic",    "rarity": "epic",      "price": 1700, "path": "res://materials/decals/galaxy_spiral.png"},
	"nebula_dust":         {"name": "Nebula Dust",           "category": "Cosmic",    "rarity": "rare",      "price": 690,  "path": "res://materials/decals/nebula_dust.png"},
	"qr_mystery":          {"name": "QR Mystery Box",        "category": "Meta",      "rarity": "legendary", "price": 3000, "path": "res://materials/decals/qr_mystery.png"},
}

## Number of decal slots supported per vehicle. Slots are positioned in a ring
## around the body mesh by _get_decal_transform_for_slot().
const DECAL_SLOT_COUNT: int = 6

## -----------------------------------------------------------------------------
## Constants — Wheel Catalogue (20 styles)
## -----------------------------------------------------------------------------
const WHEEL_CATALOGUE: Dictionary = {
	"stock_5spoke":      {"name": "Stock 5-Spoke",      "price": 0,    "rarity": "common",    "rim_color": Color(0.6, 0.6, 0.6), "glow": false},
	"stock_7spoke":      {"name": "Stock 7-Spoke",      "price": 0,    "rarity": "common",    "rim_color": Color(0.55, 0.55, 0.55), "glow": false},
	"sport_deepdish":    {"name": "Sport Deep-Dish",    "price": 450,  "rarity": "common",    "rim_color": Color(0.2, 0.2, 0.2), "glow": false},
	"sport_mesh":        {"name": "Sport Mesh",         "price": 500,  "rarity": "common",    "rim_color": Color(0.3, 0.3, 0.3), "glow": false},
	"sport_turbofan":    {"name": "Sport Turbofan",     "price": 620,  "rarity": "uncommon",  "rim_color": Color(0.4, 0.4, 0.4), "glow": false},
	"race_splitspoke":   {"name": "Race Split-Spoke",   "price": 800,  "rarity": "uncommon",  "rim_color": Color(0.1, 0.1, 0.1), "glow": false},
	"race_monoblock":    {"name": "Race Monoblock",     "price": 950,  "rarity": "uncommon",  "rim_color": Color(0.15, 0.15, 0.15), "glow": false},
	"race_concave":      {"name": "Race Concave",       "price": 1100, "rarity": "rare",      "rim_color": Color(0.05, 0.05, 0.05), "glow": false},
	"chrome_classic":    {"name": "Chrome Classic",     "price": 1200, "rarity": "rare",      "rim_color": Color(0.9, 0.9, 0.9), "glow": false},
	"chrome_star":       {"name": "Chrome Star",        "price": 1350, "rarity": "rare",      "rim_color": Color(0.95, 0.95, 0.95), "glow": false},
	"bronze_forged":     {"name": "Bronze Forged",      "price": 1100, "rarity": "rare",      "rim_color": Color(0.7, 0.45, 0.2), "glow": false},
	"gold_luxe":         {"name": "Gold Luxe",          "price": 1800, "rarity": "epic",      "rim_color": Color(1.0, 0.82, 0.2), "glow": false},
	"neon_blue":         {"name": "Neon Blue Runners",  "price": 1600, "rarity": "epic",      "rim_color": Color(0.2, 0.5, 1.0), "glow": true},
	"neon_pink":         {"name": "Neon Pink Runners",  "price": 1600, "rarity": "epic",      "rim_color": Color(1.0, 0.25, 0.7), "glow": true},
	"neon_green":        {"name": "Neon Green Runners", "price": 1600, "rarity": "epic",      "rim_color": Color(0.3, 1.0, 0.4), "glow": true},
	"holo_shift":        {"name": "Holographic Shift",  "price": 2400, "rarity": "legendary", "rim_color": Color(0.8, 0.9, 1.0), "glow": true},
	"offroad_beadlock":  {"name": "Off-Road Beadlock",  "price": 780,  "rarity": "uncommon",  "rim_color": Color(0.25, 0.25, 0.25), "glow": false},
	"drift_spoke":       {"name": "Drift Spoke",        "price": 900,  "rarity": "uncommon",  "rim_color": Color(0.2, 0.2, 0.2), "glow": false},
	"jdm_tuner":         {"name": "JDM Tuner",          "price": 1050, "rarity": "rare",      "rim_color": Color(0.15, 0.15, 0.15), "glow": false},
	"quantum_vortex":    {"name": "Quantum Vortex",     "price": 3200, "rarity": "legendary", "rim_color": Color(0.6, 0.2, 1.0), "glow": true},
}

## -----------------------------------------------------------------------------
## Constants — Spoiler Catalogue (10 styles)
## -----------------------------------------------------------------------------
const SPOILER_CATALOGUE: Dictionary = {
	"none":           {"name": "None",            "price": 0,    "rarity": "common",    "downforce": 0.0,  "drag": 0.0},
	"lip":            {"name": "Lip Spoiler",     "price": 180,  "rarity": "common",    "downforce": 0.05, "drag": 0.01},
	"ducktail":       {"name": "Ducktail",        "price": 280,  "rarity": "common",    "downforce": 0.08, "drag": 0.02},
	"bootlid":        {"name": "Bootlid Wing",    "price": 380,  "rarity": "uncommon",  "downforce": 0.12, "drag": 0.03},
	"gt_low":         {"name": "GT Low Wing",     "price": 520,  "rarity": "uncommon",  "downforce": 0.18, "drag": 0.05},
	"gt_high":        {"name": "GT High Wing",    "price": 780,  "rarity": "rare",      "downforce": 0.28, "drag": 0.08},
	"swan_neck":      {"name": "Swan Neck Wing",  "price": 1100, "rarity": "rare",      "downforce": 0.36, "drag": 0.10},
	"active_aero":    {"name": "Active Aero",     "price": 1900, "rarity": "epic",      "downforce": 0.45, "drag": 0.06},
	"le_mans":        {"name": "Le Mans Wing",    "price": 2600, "rarity": "epic",      "downforce": 0.60, "drag": 0.14},
	"quantum_fin":    {"name": "Quantum Fin",     "price": 3800, "rarity": "legendary", "downforce": 0.80, "drag": 0.09},
}

## -----------------------------------------------------------------------------
## Constants — Exhaust Catalogue (5 styles)
## -----------------------------------------------------------------------------
const EXHAUST_CATALOGUE: Dictionary = {
	"stock":           {"name": "Stock",            "price": 0,    "rarity": "common",    "tip_count": 1, "tone": "soft",   "db": 78},
	"sport_single":    {"name": "Sport Single",     "price": 320,  "rarity": "common",    "tip_count": 1, "tone": "mid",    "db": 88},
	"sport_dual":      {"name": "Sport Dual",       "price": 560,  "rarity": "uncommon",  "tip_count": 2, "tone": "mid",    "db": 92},
	"race_quad":       {"name": "Race Quad",        "price": 1200, "rarity": "rare",      "tip_count": 4, "tone": "sharp",  "db": 101},
	"quantum_ion":     {"name": "Quantum Ion Jet",  "price": 2900, "rarity": "legendary", "tip_count": 2, "tone": "hyper",  "db": 115},
}

## -----------------------------------------------------------------------------
## Constants — Underglow Patterns
## -----------------------------------------------------------------------------
const UNDERGLOW_PATTERNS: Array[String] = [
	"solid",
	"pulse",
	"strobe",
	"chase",
	"rainbow",
	"off",
]

## -----------------------------------------------------------------------------
## Constants — Misc
## -----------------------------------------------------------------------------
const CONFIG_FILE_PATH: String = "user://vehicle_configs.json"
const SNAPSHOT_SIZE: Vector2i = Vector2i(512, 512)
const DEFAULT_PAINT_COLOR: Color = Color(0.85, 0.12, 0.14)

## -----------------------------------------------------------------------------
## Exported fields
## -----------------------------------------------------------------------------
@export_node_path("Node3D") var target_vehicle_path: NodePath
@export var auto_apply_on_ready: bool = true
@export var profile_user_id: String = "local_user"

## -----------------------------------------------------------------------------
## Runtime state — canonical configuration
## -----------------------------------------------------------------------------
var paint_color: Color = DEFAULT_PAINT_COLOR
var paint_finish: String = FINISH_METALLIC
var paint_metallic: float = 0.85
var paint_roughness: float = 0.25
var paint_clearcoat: float = 0.5
var paint_pearl_shift: Color = Color(0.2, 0.4, 1.0)

var active_decals: Dictionary = {}   # slot:int -> decal_id:String
var wheels_id: String = "stock_5spoke"
var spoiler_id: String = "none"
var exhaust_id: String = "stock"
var underglow_color: Color = Color(0.1, 0.6, 1.0)
var underglow_pattern: String = "off"
var underglow_intensity: float = 1.0

## -----------------------------------------------------------------------------
## Runtime state — scene references
## -----------------------------------------------------------------------------
var _vehicle: Node3D = null
var _body_mesh: MeshInstance3D = null
var _wheel_meshes: Array = []
var _spoiler_mount: Node3D = null
var _exhaust_mount: Node3D = null
var _underglow_anchor: Node3D = null

var _paint_material: ShaderMaterial = null
var _decal_nodes: Dictionary = {}     # slot:int -> Decal
var _spoiler_instance: Node3D = null
var _exhaust_instance: Node3D = null
var _underglow_lights: Array = []
var _underglow_accum: float = 0.0

var _saved_configs: Dictionary = {}   # name -> config Dictionary

## -----------------------------------------------------------------------------
## Lifecycle
## -----------------------------------------------------------------------------
func _ready() -> void:
	if target_vehicle_path != NodePath(""):
		_vehicle = get_node_or_null(target_vehicle_path)
	if _vehicle == null:
		# Try common fallbacks — parent or sibling named "Vehicle".
		var parent_node = get_parent()
		if parent_node is Node3D:
			_vehicle = parent_node
		else:
			var sibling = get_parent().get_node_or_null("Vehicle") if get_parent() else null
			if sibling is Node3D:
				_vehicle = sibling

	if _vehicle != null:
		_discover_scene_nodes()
	else:
		push_warning("[VehicleCustomizer] No target vehicle resolved — customizer is idle.")

	_load_all_configs_from_disk()

	if auto_apply_on_ready and _vehicle != null:
		apply_full_configuration()

func _process(delta: float) -> void:
	if underglow_pattern == "off" or _underglow_lights.is_empty():
		return
	_underglow_accum += delta
	_animate_underglow(delta)

## -----------------------------------------------------------------------------
## Scene discovery
## -----------------------------------------------------------------------------
func _discover_scene_nodes() -> void:
	_body_mesh = _vehicle.get_node_or_null("BodyMesh") as MeshInstance3D
	_wheel_meshes.clear()
	for i in range(4):
		var wm = _vehicle.get_node_or_null("WheelMesh_" + str(i))
		if wm is MeshInstance3D:
			_wheel_meshes.append(wm)
	_spoiler_mount = _vehicle.get_node_or_null("SpoilerMount") as Node3D
	_exhaust_mount = _vehicle.get_node_or_null("ExhaustMount") as Node3D
	_underglow_anchor = _vehicle.get_node_or_null("UnderglowAnchor") as Node3D

	if _body_mesh == null:
		push_warning("[VehicleCustomizer] BodyMesh not found — paint and decal systems disabled.")
	if _wheel_meshes.size() < 4:
		push_warning("[VehicleCustomizer] Fewer than 4 WheelMesh_N nodes found — wheel swap will be partial.")
	if _spoiler_mount == null:
		push_warning("[VehicleCustomizer] SpoilerMount not found — spoilers disabled.")
	if _exhaust_mount == null:
		push_warning("[VehicleCustomizer] ExhaustMount not found — exhausts disabled.")

## -----------------------------------------------------------------------------
## Paint — ShaderMaterial construction
## -----------------------------------------------------------------------------
func _build_paint_shader_code() -> String:
	# A compact, procedural paint shader supporting four finishes. The shader is
	# built at runtime so the class has no hard dependency on an external .gdshader
	# asset, which keeps the customizer self-contained.
	return """
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec4 paint_color : source_color = vec4(0.85, 0.12, 0.14, 1.0);
uniform float metallic_amt : hint_range(0.0, 1.0) = 0.85;
uniform float roughness_amt : hint_range(0.0, 1.0) = 0.25;
uniform float clearcoat_amt : hint_range(0.0, 1.0) = 0.5;
uniform vec4 pearl_shift : source_color = vec4(0.2, 0.4, 1.0, 1.0);
uniform int finish_mode = 0; // 0 metallic, 1 matte, 2 chrome, 3 pearlescent
uniform float flake_density : hint_range(0.0, 50.0) = 18.0;
uniform float flake_intensity : hint_range(0.0, 1.0) = 0.25;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

void fragment() {
	vec3 base = paint_color.rgb;
	float m = metallic_amt;
	float r = roughness_amt;
	float c = clearcoat_amt;

	if (finish_mode == 1) {
		// Matte
		m = 0.0;
		r = clamp(roughness_amt + 0.55, 0.5, 1.0);
		c = 0.0;
	} else if (finish_mode == 2) {
		// Chrome — tint base heavily toward neutral metallic
		base = mix(base, vec3(0.92, 0.92, 0.94), 0.75);
		m = 1.0;
		r = 0.05;
		c = 1.0;
	} else if (finish_mode == 3) {
		// Pearlescent — Fresnel-shifted color
		float fresnel = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 3.0);
		base = mix(base, pearl_shift.rgb, fresnel);
		m = 0.6;
		r = 0.2;
		c = 0.8;
	}

	// Metallic flakes — only visible on metallic / pearl.
	if (finish_mode == 0 || finish_mode == 3) {
		vec2 flake_uv = UV * flake_density;
		float flake = step(0.97, hash21(floor(flake_uv)));
		base += vec3(flake) * flake_intensity;
	}

	ALBEDO = base;
	METALLIC = m;
	ROUGHNESS = r;
	CLEARCOAT = c;
	CLEARCOAT_ROUGHNESS = 0.1;
}
"""

func _ensure_paint_material() -> void:
	if _paint_material != null:
		return
	_paint_material = ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = _build_paint_shader_code()
	_paint_material.shader = sh

func _apply_paint_params() -> void:
	_ensure_paint_material()
	_paint_material.set_shader_parameter("paint_color", paint_color)
	_paint_material.set_shader_parameter("metallic_amt", paint_metallic)
	_paint_material.set_shader_parameter("roughness_amt", paint_roughness)
	_paint_material.set_shader_parameter("clearcoat_amt", paint_clearcoat)
	_paint_material.set_shader_parameter("pearl_shift", paint_pearl_shift)
	_paint_material.set_shader_parameter("finish_mode", _finish_to_mode(paint_finish))

func _finish_to_mode(finish: String) -> int:
	match finish:
		FINISH_METALLIC:    return 0
		FINISH_MATTE:       return 1
		FINISH_CHROME:      return 2
		FINISH_PEARLESCENT: return 3
	return 0

func set_paint(color: Color, finish: String = "") -> void:
	paint_color = color
	if finish != "" and finish in ALL_FINISHES:
		paint_finish = finish
	# Finish-specific defaults for metallic/roughness/clearcoat.
	match paint_finish:
		FINISH_METALLIC:
			paint_metallic = 0.85
			paint_roughness = 0.25
			paint_clearcoat = 0.5
		FINISH_MATTE:
			paint_metallic = 0.0
			paint_roughness = 0.85
			paint_clearcoat = 0.0
		FINISH_CHROME:
			paint_metallic = 1.0
			paint_roughness = 0.05
			paint_clearcoat = 1.0
		FINISH_PEARLESCENT:
			paint_metallic = 0.6
			paint_roughness = 0.2
			paint_clearcoat = 0.8
	_apply_paint_params()
	if _body_mesh != null:
		_body_mesh.material_override = _paint_material
	emit_signal("paint_changed", paint_color, paint_finish)

func set_paint_color_hsv(h: float, s: float, v: float) -> void:
	var c := Color.from_hsv(clamp(h, 0.0, 1.0), clamp(s, 0.0, 1.0), clamp(v, 0.0, 1.0))
	set_paint(c, paint_finish)

func set_paint_finish(finish: String) -> void:
	if not finish in ALL_FINISHES:
		push_warning("[VehicleCustomizer] Unknown finish: " + finish)
		return
	set_paint(paint_color, finish)

func set_pearl_shift(color: Color) -> void:
	paint_pearl_shift = color
	_apply_paint_params()

## -----------------------------------------------------------------------------
## Decals
## -----------------------------------------------------------------------------
func list_decal_ids() -> Array:
	return DECAL_CATALOGUE.keys()

func list_decals_by_category(category: String) -> Array:
	var out: Array = []
	for id in DECAL_CATALOGUE.keys():
		if DECAL_CATALOGUE[id].get("category", "") == category:
			out.append(id)
	return out

func get_decal_info(decal_id: String) -> Dictionary:
	if DECAL_CATALOGUE.has(decal_id):
		return DECAL_CATALOGUE[decal_id]
	return {}

func apply_decal(slot: int, decal_id: String) -> bool:
	if slot < 0 or slot >= DECAL_SLOT_COUNT:
		push_warning("[VehicleCustomizer] apply_decal: slot out of range: " + str(slot))
		return false
	if not DECAL_CATALOGUE.has(decal_id):
		push_warning("[VehicleCustomizer] apply_decal: unknown decal_id: " + decal_id)
		return false
	if _vehicle == null:
		return false

	# Reuse existing Decal node per slot to avoid churn.
	var decal_node: Decal = _decal_nodes.get(slot, null)
	if decal_node == null:
		decal_node = Decal.new()
		decal_node.name = "Decal_Slot_" + str(slot)
		decal_node.size = Vector3(1.2, 0.5, 1.2)
		decal_node.cull_mask = 1
		decal_node.upper_fade = 0.3
		decal_node.lower_fade = 0.3
		_vehicle.add_child(decal_node)
		_decal_nodes[slot] = decal_node

	var tex_path: String = DECAL_CATALOGUE[decal_id].get("path", "")
	var tex: Texture2D = null
	if tex_path != "" and ResourceLoader.exists(tex_path):
		tex = load(tex_path)
	if tex != null:
		decal_node.texture_albedo = tex

	decal_node.transform = _get_decal_transform_for_slot(slot)
	decal_node.visible = true
	active_decals[slot] = decal_id
	emit_signal("decal_applied", decal_id, slot)
	return true

func remove_decal(slot: int) -> void:
	if not active_decals.has(slot):
		return
	active_decals.erase(slot)
	if _decal_nodes.has(slot):
		var d: Decal = _decal_nodes[slot]
		d.visible = false
	emit_signal("decal_removed", slot)

func clear_all_decals() -> void:
	var slots = active_decals.keys()
	for s in slots:
		remove_decal(s)

func _get_decal_transform_for_slot(slot: int) -> Transform3D:
	# Six canonical positions: hood, roof, trunk, left door, right door, rear.
	var t := Transform3D.IDENTITY
	match slot:
		0: # Hood
			t.origin = Vector3(0.0, 0.6, 1.4)
			t.basis = Basis(Vector3.RIGHT, -PI * 0.5)
		1: # Roof
			t.origin = Vector3(0.0, 1.1, 0.0)
			t.basis = Basis(Vector3.RIGHT, -PI * 0.5)
		2: # Trunk
			t.origin = Vector3(0.0, 0.6, -1.4)
			t.basis = Basis(Vector3.RIGHT, -PI * 0.5)
		3: # Left door
			t.origin = Vector3(-0.95, 0.5, 0.0)
			t.basis = Basis(Vector3.UP, PI * 0.5) * Basis(Vector3.RIGHT, -PI * 0.5)
		4: # Right door
			t.origin = Vector3(0.95, 0.5, 0.0)
			t.basis = Basis(Vector3.UP, -PI * 0.5) * Basis(Vector3.RIGHT, -PI * 0.5)
		5: # Rear window
			t.origin = Vector3(0.0, 0.95, -0.9)
			t.basis = Basis(Vector3.RIGHT, -PI * 0.5)
	return t

## -----------------------------------------------------------------------------
## Wheels
## -----------------------------------------------------------------------------
func list_wheel_ids() -> Array:
	return WHEEL_CATALOGUE.keys()

func get_wheel_info(wheel_id: String) -> Dictionary:
	if WHEEL_CATALOGUE.has(wheel_id):
		return WHEEL_CATALOGUE[wheel_id]
	return {}

func set_wheels(wheel_id: String) -> bool:
	if not WHEEL_CATALOGUE.has(wheel_id):
		push_warning("[VehicleCustomizer] Unknown wheel_id: " + wheel_id)
		return false
	wheels_id = wheel_id
	_apply_wheels()
	emit_signal("wheels_changed", wheel_id)
	return true

func _apply_wheels() -> void:
	if _wheel_meshes.is_empty():
		return
	var info: Dictionary = WHEEL_CATALOGUE.get(wheels_id, {})
	var rim_color: Color = info.get("rim_color", Color(0.5, 0.5, 0.5))
	var glow: bool = info.get("glow", false)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = rim_color
	mat.metallic = 0.9
	mat.roughness = 0.25
	if glow:
		mat.emission_enabled = true
		mat.emission = rim_color
		mat.emission_energy_multiplier = 2.4
	for wm in _wheel_meshes:
		if wm is MeshInstance3D:
			wm.material_override = mat

## -----------------------------------------------------------------------------
## Spoiler
## -----------------------------------------------------------------------------
func list_spoiler_ids() -> Array:
	return SPOILER_CATALOGUE.keys()

func get_spoiler_info(spoiler_id_: String) -> Dictionary:
	if SPOILER_CATALOGUE.has(spoiler_id_):
		return SPOILER_CATALOGUE[spoiler_id_]
	return {}

func set_spoiler(spoiler_id_: String) -> bool:
	if not SPOILER_CATALOGUE.has(spoiler_id_):
		push_warning("[VehicleCustomizer] Unknown spoiler_id: " + spoiler_id_)
		return false
	spoiler_id = spoiler_id_
	_apply_spoiler()
	emit_signal("spoiler_changed", spoiler_id)
	return true

func _apply_spoiler() -> void:
	if _spoiler_mount == null:
		return
	if _spoiler_instance != null and is_instance_valid(_spoiler_instance):
		_spoiler_instance.queue_free()
		_spoiler_instance = null
	if spoiler_id == "none":
		return
	var info: Dictionary = SPOILER_CATALOGUE[spoiler_id]
	var mi := MeshInstance3D.new()
	mi.name = "Spoiler_" + spoiler_id
	var box := BoxMesh.new()
	box.size = Vector3(1.5, 0.08, 0.25)
	mi.mesh = box
	mi.position = Vector3(0, 0.25 + info.get("downforce", 0.0) * 0.3, 0)
	_spoiler_mount.add_child(mi)
	_spoiler_instance = mi

func get_spoiler_downforce() -> float:
	return float(SPOILER_CATALOGUE.get(spoiler_id, {}).get("downforce", 0.0))

func get_spoiler_drag() -> float:
	return float(SPOILER_CATALOGUE.get(spoiler_id, {}).get("drag", 0.0))

## -----------------------------------------------------------------------------
## Exhaust
## -----------------------------------------------------------------------------
func list_exhaust_ids() -> Array:
	return EXHAUST_CATALOGUE.keys()

func get_exhaust_info(exhaust_id_: String) -> Dictionary:
	if EXHAUST_CATALOGUE.has(exhaust_id_):
		return EXHAUST_CATALOGUE[exhaust_id_]
	return {}

func set_exhaust(exhaust_id_: String) -> bool:
	if not EXHAUST_CATALOGUE.has(exhaust_id_):
		push_warning("[VehicleCustomizer] Unknown exhaust_id: " + exhaust_id_)
		return false
	exhaust_id = exhaust_id_
	_apply_exhaust()
	emit_signal("exhaust_changed", exhaust_id)
	return true

func _apply_exhaust() -> void:
	if _exhaust_mount == null:
		return
	if _exhaust_instance != null and is_instance_valid(_exhaust_instance):
		_exhaust_instance.queue_free()
		_exhaust_instance = null
	var info: Dictionary = EXHAUST_CATALOGUE.get(exhaust_id, {})
	var tip_count: int = int(info.get("tip_count", 1))
	var group := Node3D.new()
	group.name = "Exhaust_" + exhaust_id
	var spacing: float = 0.2
	var start_x: float = -spacing * float(tip_count - 1) * 0.5
	for i in range(tip_count):
		var mi := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.06
		cyl.bottom_radius = 0.06
		cyl.height = 0.25
		mi.mesh = cyl
		mi.position = Vector3(start_x + float(i) * spacing, 0.0, 0.0)
		mi.rotation = Vector3(PI * 0.5, 0.0, 0.0)
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.15, 0.15, 0.15)
		mat.metallic = 1.0
		mat.roughness = 0.2
		mi.material_override = mat
		group.add_child(mi)
	_exhaust_mount.add_child(group)
	_exhaust_instance = group

## -----------------------------------------------------------------------------
## Underglow
## -----------------------------------------------------------------------------
func set_underglow(color: Color, pattern: String = "solid", intensity: float = 1.0) -> void:
	if not pattern in UNDERGLOW_PATTERNS:
		push_warning("[VehicleCustomizer] Unknown underglow pattern: " + pattern)
		pattern = "solid"
	underglow_color = color
	underglow_pattern = pattern
	underglow_intensity = clamp(intensity, 0.0, 4.0)
	_apply_underglow()
	emit_signal("underglow_changed", underglow_color, underglow_pattern)

func _apply_underglow() -> void:
	if _underglow_anchor == null:
		return
	# Clear existing
	for l in _underglow_lights:
		if is_instance_valid(l):
			l.queue_free()
	_underglow_lights.clear()
	if underglow_pattern == "off":
		return
	# Four lights positioned at the corners under the chassis.
	var positions := [
		Vector3(-0.9, -0.35, 1.2),
		Vector3( 0.9, -0.35, 1.2),
		Vector3(-0.9, -0.35, -1.2),
		Vector3( 0.9, -0.35, -1.2),
	]
	for p in positions:
		var ol := OmniLight3D.new()
		ol.light_color = underglow_color
		ol.light_energy = underglow_intensity * 1.8
		ol.omni_range = 2.6
		ol.position = p
		_underglow_anchor.add_child(ol)
		_underglow_lights.append(ol)

func _animate_underglow(_delta: float) -> void:
	match underglow_pattern:
		"solid":
			for l in _underglow_lights:
				l.light_color = underglow_color
				l.light_energy = underglow_intensity * 1.8
		"pulse":
			var amp: float = 0.5 + 0.5 * sin(_underglow_accum * TAU * 1.2)
			for l in _underglow_lights:
				l.light_energy = underglow_intensity * (0.6 + 1.4 * amp)
		"strobe":
			var on: bool = int(_underglow_accum * 8.0) % 2 == 0
			for l in _underglow_lights:
				l.light_energy = underglow_intensity * (2.2 if on else 0.0)
		"chase":
			for i in range(_underglow_lights.size()):
				var phase: float = fposmod(_underglow_accum * 2.0 - float(i) * 0.25, 1.0)
				_underglow_lights[i].light_energy = underglow_intensity * (0.2 + 2.0 * pow(1.0 - phase, 3.0))
		"rainbow":
			var hue: float = fposmod(_underglow_accum * 0.25, 1.0)
			var c := Color.from_hsv(hue, 0.85, 1.0)
			for l in _underglow_lights:
				l.light_color = c
				l.light_energy = underglow_intensity * 1.8

## -----------------------------------------------------------------------------
## Full apply / reset
## -----------------------------------------------------------------------------
func apply_full_configuration() -> void:
	_apply_paint_params()
	if _body_mesh != null:
		_body_mesh.material_override = _paint_material
	# Re-apply decals from stored active_decals dictionary.
	var slots = active_decals.keys()
	for s in slots:
		apply_decal(s, active_decals[s])
	_apply_wheels()
	_apply_spoiler()
	_apply_exhaust()
	_apply_underglow()

func reset_to_stock() -> void:
	paint_color = DEFAULT_PAINT_COLOR
	paint_finish = FINISH_METALLIC
	set_paint(paint_color, paint_finish)
	clear_all_decals()
	set_wheels("stock_5spoke")
	set_spoiler("none")
	set_exhaust("stock")
	set_underglow(Color(0.1, 0.6, 1.0), "off", 1.0)

## -----------------------------------------------------------------------------
## Configuration serialization
## -----------------------------------------------------------------------------
func export_configuration() -> Dictionary:
	return {
		"version": 1,
		"owner": profile_user_id,
		"paint": {
			"color": [paint_color.r, paint_color.g, paint_color.b, paint_color.a],
			"finish": paint_finish,
			"metallic": paint_metallic,
			"roughness": paint_roughness,
			"clearcoat": paint_clearcoat,
			"pearl_shift": [paint_pearl_shift.r, paint_pearl_shift.g, paint_pearl_shift.b, paint_pearl_shift.a],
		},
		"decals": active_decals.duplicate(true),
		"wheels": wheels_id,
		"spoiler": spoiler_id,
		"exhaust": exhaust_id,
		"underglow": {
			"color": [underglow_color.r, underglow_color.g, underglow_color.b, underglow_color.a],
			"pattern": underglow_pattern,
			"intensity": underglow_intensity,
		},
	}

func import_configuration(cfg: Dictionary) -> bool:
	if cfg.is_empty():
		return false
	var paint: Dictionary = cfg.get("paint", {})
	if not paint.is_empty():
		var c_arr = paint.get("color", [DEFAULT_PAINT_COLOR.r, DEFAULT_PAINT_COLOR.g, DEFAULT_PAINT_COLOR.b, 1.0])
		paint_color = Color(c_arr[0], c_arr[1], c_arr[2], c_arr[3] if c_arr.size() > 3 else 1.0)
		paint_finish = String(paint.get("finish", FINISH_METALLIC))
		paint_metallic = float(paint.get("metallic", 0.85))
		paint_roughness = float(paint.get("roughness", 0.25))
		paint_clearcoat = float(paint.get("clearcoat", 0.5))
		var p_arr = paint.get("pearl_shift", [0.2, 0.4, 1.0, 1.0])
		paint_pearl_shift = Color(p_arr[0], p_arr[1], p_arr[2], p_arr[3] if p_arr.size() > 3 else 1.0)

	active_decals.clear()
	var raw_decals: Dictionary = cfg.get("decals", {})
	for k in raw_decals.keys():
		active_decals[int(k)] = String(raw_decals[k])

	wheels_id = String(cfg.get("wheels", "stock_5spoke"))
	spoiler_id = String(cfg.get("spoiler", "none"))
	exhaust_id = String(cfg.get("exhaust", "stock"))

	var ug: Dictionary = cfg.get("underglow", {})
	if not ug.is_empty():
		var uc_arr = ug.get("color", [0.1, 0.6, 1.0, 1.0])
		underglow_color = Color(uc_arr[0], uc_arr[1], uc_arr[2], uc_arr[3] if uc_arr.size() > 3 else 1.0)
		underglow_pattern = String(ug.get("pattern", "off"))
		underglow_intensity = float(ug.get("intensity", 1.0))

	apply_full_configuration()
	return true

func save_configuration(config_name: String) -> bool:
	if config_name == "":
		return false
	_saved_configs[config_name] = export_configuration()
	var ok := _persist_configs_to_disk()
	if ok:
		emit_signal("configuration_saved", config_name)
	return ok

func load_configuration(config_name: String) -> bool:
	if not _saved_configs.has(config_name):
		push_warning("[VehicleCustomizer] No saved config named: " + config_name)
		return false
	var ok := import_configuration(_saved_configs[config_name])
	if ok:
		emit_signal("configuration_loaded", config_name)
	return ok

func delete_configuration(config_name: String) -> bool:
	if not _saved_configs.has(config_name):
		return false
	_saved_configs.erase(config_name)
	return _persist_configs_to_disk()

func list_saved_configurations() -> Array:
	return _saved_configs.keys()

func _persist_configs_to_disk() -> bool:
	var f := FileAccess.open(CONFIG_FILE_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("[VehicleCustomizer] Could not open config file for write.")
		return false
	f.store_string(JSON.stringify({"version": 1, "configs": _saved_configs}))
	f.close()
	return true

func _load_all_configs_from_disk() -> void:
	if not FileAccess.file_exists(CONFIG_FILE_PATH):
		return
	var f := FileAccess.open(CONFIG_FILE_PATH, FileAccess.READ)
	if f == null:
		return
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var cfgs = parsed.get("configs", {})
	if typeof(cfgs) == TYPE_DICTIONARY:
		_saved_configs = cfgs

## -----------------------------------------------------------------------------
## Pricing helpers
## -----------------------------------------------------------------------------
func price_of_decal(decal_id: String) -> int:
	return int(DECAL_CATALOGUE.get(decal_id, {}).get("price", 0))

func price_of_wheels(wheel_id: String) -> int:
	return int(WHEEL_CATALOGUE.get(wheel_id, {}).get("price", 0))

func price_of_spoiler(spoiler_id_: String) -> int:
	return int(SPOILER_CATALOGUE.get(spoiler_id_, {}).get("price", 0))

func price_of_exhaust(exhaust_id_: String) -> int:
	return int(EXHAUST_CATALOGUE.get(exhaust_id_, {}).get("price", 0))

func total_configuration_price() -> int:
	var sum := 0
	for slot_id in active_decals.keys():
		sum += price_of_decal(active_decals[slot_id])
	sum += price_of_wheels(wheels_id)
	sum += price_of_spoiler(spoiler_id)
	sum += price_of_exhaust(exhaust_id)
	return sum

## -----------------------------------------------------------------------------
## Snapshots (for marketplace / garage collection thumbnails)
## -----------------------------------------------------------------------------
func capture_snapshot() -> Image:
	var vp := get_viewport()
	if vp == null:
		return null
	var tex := vp.get_texture()
	if tex == null:
		return null
	var img := tex.get_image()
	if img == null:
		return null
	img.resize(SNAPSHOT_SIZE.x, SNAPSHOT_SIZE.y, Image.INTERPOLATE_LANCZOS)
	emit_signal("snapshot_captured", img)
	return img

## -----------------------------------------------------------------------------
## Convenience queries
## -----------------------------------------------------------------------------
func summary_string() -> String:
	var parts := PackedStringArray()
	parts.append("Paint: #" + paint_color.to_html(false) + " " + paint_finish)
	parts.append("Wheels: " + String(WHEEL_CATALOGUE.get(wheels_id, {}).get("name", wheels_id)))
	parts.append("Spoiler: " + String(SPOILER_CATALOGUE.get(spoiler_id, {}).get("name", spoiler_id)))
	parts.append("Exhaust: " + String(EXHAUST_CATALOGUE.get(exhaust_id, {}).get("name", exhaust_id)))
	parts.append("Decals: " + str(active_decals.size()))
	parts.append("Underglow: " + underglow_pattern)
	return " | ".join(parts)
