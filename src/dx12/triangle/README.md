# triangle

`M-x ewv-dx12-triangle`: a triangle with a red, a green and a blue corner,
turning once every six seconds on a black background.

It is the Direct3D 12 counterpart of appine's `appine-metal-triangle`, which
runs Apple's [Drawing a triangle with Metal 4](https://developer.apple.com/documentation/metal/drawing-a-triangle-with-metal-4)
sample. The structure follows Microsoft's D3D12HelloTriangle sample: an empty
root signature, one pipeline state, one vertex buffer, and per frame a clear
and a three-vertex draw.

| File | |
|---|---|
| `mod.rs` | The renderer (`Triangle`) |
| `shaders.hlsl` | Vertex and pixel shader, compiled at first use with `D3DCompile` |

Two things differ from the samples because the view lives in an Emacs window
of any shape:

- The rotation is done on the CPU: the vertex buffer stays mapped and its
  three vertices are rewritten every frame, already rotated. That keeps the
  shaders to a pass-through and needs no constant buffer.
- The triangle is scaled by the window's aspect ratio, so it stays undistorted
  and inside the view in a wide window and in a tall one.
