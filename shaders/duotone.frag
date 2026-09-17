#version 440
// Maps artwork onto the Omarchy theme: luminance picks a colour on a
// shadow -> highlight ramp, with a little lift towards `peak` at the very top
// so bright art stays readable. `amount` blends back to the original, and
// `circle`/`hole` cut the image into a record label.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 shadow;
    vec4 highlight;
    vec4 peak;
    float amount;
    float contrast;
    float circle;
    float hole;
};

layout(binding = 1) uniform sampler2D source;

void main() {
    vec4 c = texture(source, qt_TexCoord0);
    vec3 rgb = c.a > 0.0 ? c.rgb / c.a : c.rgb;
    float l = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
    l = clamp((l - 0.5) * contrast + 0.5, 0.0, 1.0);
    l = l * l * (3.0 - 2.0 * l);
    vec3 duo = mix(shadow.rgb, highlight.rgb, l);
    duo = mix(duo, peak.rgb, smoothstep(0.82, 1.0, l) * 0.6);
    vec3 outRgb = mix(rgb, duo, amount);

    float a = c.a;
    if (circle > 0.5) {
        float r = length(qt_TexCoord0 - 0.5) * 2.0;
        float aa = max(fwidth(r), 0.002);
        a *= 1.0 - smoothstep(1.0 - aa, 1.0, r);
        a *= smoothstep(hole, hole + aa, r);
    }
    fragColor = vec4(outRgb * a, a) * qt_Opacity;
}
