#version 120
attribute vec4 aPos;
attribute float x_pos;

varying float frag_x_pos;

void main()
{
        gl_Position = aPos;
        frag_x_pos = x_pos;
}
