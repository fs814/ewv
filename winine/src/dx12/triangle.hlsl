// The triangle demo's shaders, copied from ewv's src/dx12/triangle/shaders.hlsl.
// CMakeLists.txt compiles them with fxc (vs_5_0 / ps_5_0) into triangle_vs.h
// and triangle_ps.h; see triangle.cpp.
//
// Positions arrive already rotated and aspect-corrected in clip space: the
// renderer rewrites the three vertices every frame.

struct VSInput {
    float3 position : POSITION;
    float4 color : COLOR;
};

struct PSInput {
    float4 position : SV_POSITION;
    float4 color : COLOR;
};

PSInput VSMain(VSInput input) {
    PSInput output;
    output.position = float4(input.position, 1.0);
    output.color = input.color;
    return output;
}

float4 PSMain(PSInput input) : SV_TARGET {
    return input.color;
}
