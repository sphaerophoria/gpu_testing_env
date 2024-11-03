#version 120
varying vec2 uv;

void main()
{
    gl_FragColor = vec4(uv, 0.0, 1.0);
}
