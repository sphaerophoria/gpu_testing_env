#version 120

varying float frag_x_pos;

void main()
{
    float val = sin(frag_x_pos * 100);
    gl_FragColor = vec4(val, val, val, 1.0);
}
