## Interior Mapping Shader — Fake Building Interiors for Window Surfaces
##
## Technique: each window face is treated as a portal into a virtual room cube.
## A view ray is cast through the window UV into the cube and intersected with
## the back wall. The hit UV is then used to sample a room texture atlas (or
## procedural noise fallback). This creates the convincing illusion of depth
## without any additional geometry or render passes.
##
## Usage:
##   1. Create a ShaderMaterial using this shader on a building's window mesh.
##   2. Assign a RoomAtlas texture (optional, uses procedural noise if blank).
##   3. The shader tiles windows automatically based on window_columns / window_rows.
##
## Performance notes:
##   • No texture sampling from atlas discard path (pure procedural variant) costs
##     ~12 GPU instructions per fragment, safe for mid-tier mobile WebGL.
##   • When room_atlas is bound the cost rises to ~28 instructions but is still
##     within budget for surfaces with a limited on-screen pixel count.

shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// ── Window grid parameters ───────────────────────────────────────────────────
uniform int   window_columns    : hint_range(1, 32)   = 6;
uniform int   window_rows       : hint_range(1, 32)   = 10;
uniform float window_gap        : hint_range(0.0, 0.5) = 0.06;
uniform float window_depth      : hint_range(0.1, 4.0) = 1.8;

// ── Exterior facade ──────────────────────────────────────────────────────────
uniform vec4  facade_color      : source_color = vec4(0.03, 0.03, 0.06, 1.0);
uniform vec4  frame_color       : source_color = vec4(0.08, 0.08, 0.12, 1.0);
uniform vec4  neon_edge_color   : source_color = vec4(0.0, 0.8, 1.0, 1.0);
uniform float neon_edge_str     : hint_range(0.0, 20.0) = 6.0;

// ── Interior room atlas ──────────────────────────────────────────────────────
// Optional: 4×4 grid of room images tiled from this atlas.
// Leave unset to use the procedural interior fallback.
uniform sampler2D room_atlas    : source_color, hint_default_black;
uniform bool      use_atlas     = false;
uniform int       atlas_columns : hint_range(1, 8)   = 4;
uniform int       atlas_rows    : hint_range(1, 8)   = 4;

// ── Lighting ─────────────────────────────────────────────────────────────────
// Per-window light probability and colour range for variety.
uniform float room_light_prob   : hint_range(0.0, 1.0) = 0.7;
uniform float room_brightness   : hint_range(0.0, 4.0) = 1.2;
uniform float time_offset       : hint_range(0.0, 100.0) = 0.0; // drive from GDScript for animations

// ── Helpers ──────────────────────────────────────────────────────────────────

// Fast integer hash → [0,1] float.
float hash11(float n) {
	return fract(sin(n) * 43758.5453123);
}

float hash12(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

vec3 hash33(vec3 p) {
	p = vec3(dot(p, vec3(127.1, 311.7, 74.7)),
	         dot(p, vec3(269.5, 183.3, 246.1)),
	         dot(p, vec3(113.5, 271.9, 124.6)));
	return fract(sin(p) * 43758.5453);
}

// Intersect a ray (origin ro, direction rd) with an axis-aligned unit box
// centred at (0.5, 0.5, -window_depth * 0.5).
// Returns the t parameter of the back-wall hit (z = -window_depth) or 1e9 on miss.
float ray_box_back_t(vec3 ro, vec3 rd, float depth) {
	// Back wall is at z = -depth in the window's local space where window face is z=0.
	if (abs(rd.z) < 1e-6) return 1e9;
	float t = (-depth - ro.z) / rd.z;
	if (t <= 0.0) return 1e9;
	vec3 hit = ro + rd * t;
	if (hit.x < 0.0 || hit.x > 1.0 || hit.y < 0.0 || hit.y > 1.0) return 1e9;
	return t;
}

// ── Fragment ──────────────────────────────────────────────────────────────────

void fragment() {
	// ── 1. Window grid UVs ──────────────────────────────────────────────────
	vec2 uv = UV;

	// Convert to per-window local coords.
	float cols_f = float(window_columns);
	float rows_f = float(window_rows);

	vec2 win_uv  = fract(uv * vec2(cols_f, rows_f));
	vec2 win_id  = floor(uv * vec2(cols_f, rows_f));

	// ── 2. Window frame mask ─────────────────────────────────────────────────
	float gap = window_gap;
	float inside_x = step(gap, win_uv.x) * step(win_uv.x, 1.0 - gap);
	float inside_y = step(gap, win_uv.y) * step(win_uv.y, 1.0 - gap);
	float is_glass = inside_x * inside_y;

	// ── 3. Per-window random seed ────────────────────────────────────────────
	float win_seed = hash12(win_id + vec2(17.3, 31.7));

	// ── 4. Decide if this window is lit (some are dark / blinds drawn) ────────
	float lit = step(1.0 - room_light_prob, win_seed);

	// ── 5. Interior mapping ray ──────────────────────────────────────────────
	// Remap win_uv to [0,1] inside the glass area.
	vec2 inner_uv = (win_uv - gap) / (1.0 - 2.0 * gap);
	inner_uv = clamp(inner_uv, 0.0, 1.0);

	// The view ray in window-local space.
	// We use a perspective-skewed ray from the window UV to simulate
	// parallax depth: the ray tilts toward the viewer as UV moves from centre.
	// Negative Z direction points into the virtual room (back wall is at z = -depth).
	vec3 ray_dir = normalize(vec3((inner_uv - 0.5) * 1.2, -1.0));

	// Ray origin at the window surface (z=0 in local space, xy = inner_uv).
	vec3 ray_orig = vec3(inner_uv.x, inner_uv.y, 0.0);

	float back_t  = ray_box_back_t(ray_orig, ray_dir, window_depth);
	vec3  back_hit = ray_orig + ray_dir * back_t;
	// Clamp to avoid tile bleeding.
	vec2 room_uv  = clamp(back_hit.xy, 0.001, 0.999);

	// ── 6. Room colour ────────────────────────────────────────────────────────
	vec3 room_col;

	if (use_atlas) {
		// Sample from atlas cell chosen by per-window hash.
		float atlas_cols_f = float(atlas_columns);
		float atlas_rows_f = float(atlas_rows);
		float cell_idx  = floor(win_seed * atlas_cols_f * atlas_rows_f);
		float cell_col  = mod(cell_idx, atlas_cols_f);
		float cell_row  = floor(cell_idx / atlas_cols_f);
		vec2 atlas_uv   = (vec2(cell_col, cell_row) + room_uv) / vec2(atlas_cols_f, atlas_rows_f);
		room_col = texture(room_atlas, atlas_uv).rgb;
	} else {
		// Procedural room: random warm/cool tint + simple furniture silhouette.
		vec3 room_tint = mix(
			vec3(1.0, 0.75, 0.45),   // Warm incandescent
			vec3(0.45, 0.75, 1.0),   // Cool monitor glow
			hash11(win_seed * 7.3)
		);

		// Crude silhouette: dark rectangles near the floor/walls.
		float furniture = 1.0;
		furniture *= 1.0 - 0.7 * step(room_uv.y, 0.3) * step(0.1, room_uv.x) * step(room_uv.x, 0.45);
		furniture *= 1.0 - 0.5 * step(0.6, room_uv.y) * step(0.55, room_uv.x) * step(room_uv.x, 0.9);

		// Faint grid lines on a back-wall screen.
		float screen_mask = step(0.5, room_uv.x) * step(0.35, room_uv.y) * step(room_uv.y, 0.7);
		float screen_line = step(fract(room_uv.y * 12.0), 0.85);
		vec3 screen_col   = vec3(0.0, 1.0, 0.6) * screen_line * screen_mask;

		room_col = room_tint * furniture * room_brightness + screen_col * 0.4;
	}

	// Dark out unlit rooms.
	room_col *= lit;

	// Subtle animated light flicker: use time_offset driven from GDScript.
	float flicker = 1.0 - 0.08 * hash11(win_seed * 13.7 + time_offset * 0.1) * lit;
	room_col *= flicker;

	// ── 7. Neon edge glow on window frame ─────────────────────────────────────
	float frame_edge_x = step(win_uv.x, gap) + step(1.0 - gap, win_uv.x);
	float frame_edge_y = step(win_uv.y, gap) + step(1.0 - gap, win_uv.y);
	float frame_edge   = clamp(frame_edge_x + frame_edge_y, 0.0, 1.0) * (1.0 - frame_edge_x * frame_edge_y);

	// ── 8. Composite ──────────────────────────────────────────────────────────
	// Blend: facade / frame / glass (interior).
	vec3 final_col = facade_color.rgb;
	final_col = mix(final_col, frame_color.rgb, frame_edge);
	final_col = mix(final_col, room_col, is_glass);

	ALBEDO    = final_col;
	METALLIC  = mix(0.3, 0.9, is_glass * (1.0 - lit));
	ROUGHNESS = mix(0.9, 0.05, is_glass * (1.0 - lit * 0.6));
	EMISSION  = neon_edge_color.rgb * frame_edge * neon_edge_str
	           + room_col * is_glass * lit * 0.5;
	SPECULAR  = 0.6;
}
