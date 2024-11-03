#version 120
attribute vec3 aPos;
attribute vec2 in_uv;

uniform mat4 transform;

varying vec2 uv;

void main()
{
        gl_Position = vec4(transform * vec4(aPos, 1.0));
        uv = in_uv;
}
