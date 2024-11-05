#version 120
varying vec2 uv;

uniform sampler2D tex;

void main()
{
    gl_FragColor = texture2D(tex, uv);
}
