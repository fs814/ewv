# raytracing

`M-x ewv-dx12-raytracing`: a 3 x 3 grid of Cornell boxes, path traced with
DirectX Raytracing (DXR). The image starts noisy and converges as frames
accumulate; resizing the window restarts it.

It is the Direct3D 12 counterpart of appine's `appine-metal-raytracing`, which
runs Apple's [Accelerating ray tracing using Metal](https://developer.apple.com/documentation/metal/accelerating-ray-tracing-using-metal)
sample. What that sample demonstrates, and where it is here:

| The Metal sample | This demo |
|---|---|
| One Cornell box, instanced many times | One bottom-level acceleration structure for the box, 9 instances in the top level |
| Spheres that are bounding boxes with an intersection function | A second bottom-level structure holding one AABB, and the `SphereIntersection` shader |
| A different look per instance | The shader colors the two side walls from the instance number; the middle box keeps the classic red and green |
| An area light per box, sampled directly with shadow rays | The same, in `RayGen` |
| Paths traced in a loop, accumulated over frames | The same: `RayGen` loops over bounces (trace depth 1) and averages into a float texture |

| File | |
|---|---|
| `mod.rs` | The scene, the acceleration structures, the ray tracing pipeline and the per-frame dispatch (`RayTracing`) |
| `shaders.hlsl` | The DXR shader library: ray generation, two miss shaders, the triangle and sphere hit groups |

## Requirements

A GPU and driver with DirectX Raytracing tier 1.0 or later (NVIDIA RTX and
GTX 10-series with current drivers, AMD RX 6000 and later, Intel Arc). Without
one, the buffer says so and no view appears.

## Notes

- **Shaders are compiled at build time.** See `../README.md`. The constants at
  the top of `shaders.hlsl` (sphere, light) repeat ones in `mod.rs`; the scene
  is small enough that passing them through a buffer would only hide them.
- **Per-triangle data.** The closest-hit shader needs each triangle's normal
  and color. They are in one buffer indexed by `PrimitiveIndex()`. The box
  instances are only translated, so the normals need no transform.
- **One root signature.** Everything the shaders read is bound globally, so
  the shader table holds bare shader identifiers and no local root arguments.
- **The camera** looks at the middle box and backs away until the whole grid
  fits, whatever the window's shape.
