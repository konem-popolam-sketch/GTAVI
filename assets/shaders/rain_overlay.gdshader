shader_type canvas_item;
render_mode blend_mix, unshaded;

// NIGHT SHIFT — изморось/дождь на экране, CanvasLayer поверх 3D (по желанию).
//
// Подключение (интегратор):
//   CanvasLayer (layer = 10)
//     └ ColorRect (anchors full rect, mouse_filter = MOUSE_FILTER_IGNORE)
//            material = res://assets/materials/rain_overlay.tres
// Штрихи тонкие (≈1 px при 1280 ширины), поэтому HUD и диалоги остаются читаемыми.
// Включать только если кадр не «сереет» — intensity выше 0.25 уже мешает.

uniform float intensity : hint_range(0.0, 0.5) = 0.15;
uniform vec4 rain_tint : source_color = vec4(0.62, 0.72, 0.9, 1.0);
uniform float fall_speed : hint_range(0.0, 4.0) = 1.2;
uniform float columns : hint_range(20.0, 600.0) = 240.0;
uniform float rows : hint_range(2.0, 40.0) = 13.0;
uniform float streak_len : hint_range(0.1, 1.0) = 0.55;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

void fragment() {
	vec2 uv = UV;
	float alpha = 0.0;
	for (int i = 0; i < 2; i++) {
		float layer = float(i);
		float speed = fall_speed * (1.0 + layer * 0.5);
		vec2 grid = vec2(uv.x * columns * (1.0 + layer * 0.6), uv.y * rows * (1.0 + layer * 0.4) - TIME * speed);
		vec2 cell = floor(grid);
		vec2 f = fract(grid);
		float h = hash21(vec2(cell.x, layer * 7.0));
		// тонкий штрих по центру ячейки + смещение от случайности
		float center = 0.5 + (h - 0.5) * 0.5;
		float thin = smoothstep(0.06, 0.0, abs(f.x - center));
		float visible = step(0.72 + layer * 0.08, hash21(cell + layer * 31.7));
		float tail = smoothstep(streak_len, 0.0, f.y);
		alpha += thin * visible * tail * (0.75 - layer * 0.25);
	}
	COLOR = vec4(rain_tint.rgb, clamp(alpha, 0.0, 1.0) * intensity);
}
