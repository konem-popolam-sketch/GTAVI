shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx, depth_draw_opaque, cull_back;

// NIGHT SHIFT — влажный асфальт (опциональный апгрейд стандартного материала).
//
// Что даёт поверх assets/materials/asphalt.tres:
//   * процедурные лужи (fbm) — сухой асфальт roughness ~0.85 против зеркальных
//     луж roughness ~0.1, металличность и specular тоже уходят в «мокрое»;
//   * расходящиеся кольца от капель дождя (два слоя, jittered grid) — нормаль
//     возмущается в мировом пространстве, а не картой нормалей;
//   * никаких текстур: всё считается в шейдере, ассеты не нужны.
//
// Подключение (интегратор):
//   var m = load("res://assets/materials/asphalt_wet.tres")   # ShaderMaterial
//   $World/Ground.material_override = m   # или material = m
// Если читаемость просядет — верни StandardMaterial3D res://assets/materials/asphalt.tres.

uniform vec4 dry_color : source_color = vec4(0.075, 0.078, 0.09, 1.0);
uniform vec4 wet_color : source_color = vec4(0.035, 0.038, 0.048, 1.0);
uniform float puddle_scale : hint_range(0.005, 0.6) = 0.09;
uniform float puddle_bias : hint_range(0.0, 1.0) = 0.45;
uniform float puddle_contrast : hint_range(0.5, 6.0) = 2.0;
uniform float dry_roughness : hint_range(0.0, 1.0) = 0.5;
uniform float wet_roughness : hint_range(0.0, 1.0) = 0.07;
uniform float asphalt_metallic : hint_range(0.0, 1.0) = 0.4;
uniform float rain_amount : hint_range(0.0, 1.0) = 0.55;
uniform float rain_speed : hint_range(0.0, 4.0) = 1.0;
uniform float ripple_scale = 2.4;
uniform float ripple_strength : hint_range(0.0, 1.0) = 0.3;

varying vec3 world_pos;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		v += a * value_noise(p);
		p *= 2.03;
		a *= 0.5;
	}
	return v;
}

// Кольца от капель: в каждой ячейке сетки свой центр и своя фаза.
vec2 ripple(vec2 p, float t) {
	vec2 g = floor(p);
	vec2 f = fract(p);
	vec2 jitter = vec2(hash21(g), hash21(g + 17.3));
	vec2 center = 0.25 + jitter * 0.5;
	vec2 delta = f - center;
	float d = length(delta);
	float phase = fract(t * (0.55 + jitter.x * 0.9) + jitter.y);
	float wave = sin((d - phase) * 26.0) * exp(-d * 7.0) * (1.0 - phase);
	return normalize(delta + vec2(1e-5)) * wave;
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = world_pos.xz * puddle_scale;
	float blob = fbm(p * 1.7);
	float wet_mask = clamp((smoothstep(puddle_bias - 0.16, puddle_bias + 0.16, blob) - 0.5) * puddle_contrast + 0.5, 0.0, 1.0);

	ALBEDO = mix(dry_color.rgb, wet_color.rgb, wet_mask);
	ROUGHNESS = mix(dry_roughness, wet_roughness, wet_mask);
	METALLIC = mix(asphalt_metallic * 0.35, asphalt_metallic, wet_mask);
	SPECULAR = mix(0.55, 0.8, wet_mask);

	if (rain_amount > 0.001) {
		vec2 r = ripple(world_pos.xz * ripple_scale, TIME * rain_speed);
		r += ripple(world_pos.xz * ripple_scale * 1.7 + vec2(5.2, 3.1), TIME * rain_speed * 1.35) * 0.7;
		vec3 world_normal_offset = vec3(r.x, 0.0, r.y);
		vec3 view_normal_offset = (VIEW_MATRIX * vec4(world_normal_offset, 0.0)).xyz;
		NORMAL = normalize(NORMAL + view_normal_offset * ripple_strength * 0.75 * rain_amount * wet_mask);
	}
}
