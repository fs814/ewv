//! A path-traced grid of Cornell boxes with DirectX Raytracing: the Direct3D
//! 12 counterpart of appine's Metal ray tracing demo (Apple's "Accelerating
//! ray tracing using Metal"). See README.md here.
//!
//! Like that sample: one Cornell box is built once and instanced (3 x 3), each
//! box holds a sphere that is not triangles but a bounding box with an
//! intersection shader (Metal: an intersection function), every box has its
//! own area light, and frames accumulate so the image converges.

use super::*;
use windows::core::PCWSTR;

/// shaders.hlsl compiled to a DXIL library by build.rs.
static SHADER_LIBRARY: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/raytracing_shaders.dxil"));

const BOXES_PER_ROW: u32 = 3;
const BOX_COUNT: u32 = BOXES_PER_ROW * BOXES_PER_ROW;
/// Boxes are 2 units wide and tall; the gap keeps neighbors' walls apart.
const BOX_SPACING: f32 = 2.15;

// These must match the constants at the top of shaders.hlsl.
const SPHERE_CENTER: [f32; 3] = [0.42, 0.35, 0.35];
const SPHERE_RADIUS: f32 = 0.35;
const LIGHT_Y: f32 = 1.98;
const LIGHT_HALF_SIZE: f32 = 0.3;
const FLAG_EMISSIVE: u32 = 2;
const FLAG_LEFT_WALL: u32 = 4;
const FLAG_RIGHT_WALL: u32 = 8;
// struct Payload and struct SphereAttributes in shaders.hlsl.
const PAYLOAD_SIZE: u32 = 48;
const ATTRIBUTE_SIZE: u32 = 12;

const ACCUM_FORMAT: DXGI_FORMAT = DXGI_FORMAT_R32G32B32A32_FLOAT;
const SHADER_ID_SIZE: usize = D3D12_SHADER_IDENTIFIER_SIZE_IN_BYTES as usize;
/// One 64-byte slot per shader table (64 is the required table alignment).
const TABLE_SLOT: usize = 64;

#[repr(C)]
#[derive(Clone, Copy)]
struct FrameConstants {
    camera_position: [f32; 3],
    frame_index: u32,
    camera_right: [f32; 3],
    tan_half_fov: f32,
    camera_up: [f32; 3],
    aspect: f32,
    camera_forward: [f32; 3],
    boxes_per_row: u32,
    box_spacing: f32,
    padding: [f32; 3],
}

#[repr(C)]
#[derive(Clone, Copy)]
struct TriangleInfo {
    normal: [f32; 3],
    flags: u32,
    color: [f32; 3],
    padding: f32,
}

pub struct RayTracing {
    list4: ID3D12GraphicsCommandList4,
    root_signature: ID3D12RootSignature,
    state_object: ID3D12StateObject,
    shader_table: ID3D12Resource,
    top_level: ID3D12Resource,
    triangle_info: ID3D12Resource,
    constants: ID3D12Resource,
    constants_ptr: *mut FrameConstants,
    uav_heap: ID3D12DescriptorHeap,
    uav_size: usize,
    accum: Option<ID3D12Resource>,
    output: Option<ID3D12Resource>,
    frame_index: u32,
    /// Bottom-level structures and their inputs; the top level refers to them.
    _keep_alive: Vec<ID3D12Resource>,
}

// ---------------------------------------------------------------------------
// Scene: one Cornell box, in its own space (x and z in -1..1, y in 0..2, open
// toward +z where the camera is)
// ---------------------------------------------------------------------------

struct BoxMesh {
    vertices: Vec<[f32; 3]>,
    triangles: Vec<TriangleInfo>,
}

impl BoxMesh {
    fn quad(&mut self, corners: [[f32; 3]; 4], normal: [f32; 3], color: [f32; 3], flags: u32) {
        for i in [0, 1, 2, 0, 2, 3] {
            self.vertices.push(corners[i]);
        }
        for _ in 0..2 {
            self.triangles.push(TriangleInfo { normal, flags, color, padding: 0.0 });
        }
    }

    /// An upright box standing on the floor, turned by `angle` around y.
    fn block(&mut self, center: [f32; 2], half: [f32; 2], height: f32, angle: f32, color: [f32; 3]) {
        let (sin, cos) = angle.sin_cos();
        let turn = |x: f32, z: f32| [x * cos + z * sin, -x * sin + z * cos];
        let corner = |sx: f32, sz: f32, y: f32| {
            let [x, z] = turn(sx * half[0], sz * half[1]);
            [center[0] + x, y, center[1] + z]
        };
        // Four sides: each spans two neighboring corners of the footprint.
        let footprint = [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)];
        for i in 0..4 {
            let (ax, az) = footprint[i];
            let (bx, bz) = footprint[(i + 1) % 4];
            let [nx, nz] = turn((ax + bx) * 0.5, (az + bz) * 0.5);
            self.quad(
                [corner(ax, az, 0.0), corner(bx, bz, 0.0), corner(bx, bz, height), corner(ax, az, height)],
                [nx, 0.0, nz],
                color,
                0,
            );
        }
        self.quad(
            [
                corner(-1.0, -1.0, height),
                corner(1.0, -1.0, height),
                corner(1.0, 1.0, height),
                corner(-1.0, 1.0, height),
            ],
            [0.0, 1.0, 0.0],
            color,
            0,
        );
    }

    fn cornell_box() -> BoxMesh {
        let mut mesh = BoxMesh { vertices: Vec::new(), triangles: Vec::new() };
        let white = [0.73, 0.73, 0.73];
        // floor, ceiling, back wall
        mesh.quad([[-1.0, 0.0, -1.0], [1.0, 0.0, -1.0], [1.0, 0.0, 1.0], [-1.0, 0.0, 1.0]], [0.0, 1.0, 0.0], white, 0);
        mesh.quad([[-1.0, 2.0, -1.0], [1.0, 2.0, -1.0], [1.0, 2.0, 1.0], [-1.0, 2.0, 1.0]], [0.0, -1.0, 0.0], white, 0);
        mesh.quad([[-1.0, 0.0, -1.0], [1.0, 0.0, -1.0], [1.0, 2.0, -1.0], [-1.0, 2.0, -1.0]], [0.0, 0.0, 1.0], white, 0);
        // left and right walls; the shader colors them per box
        mesh.quad([[-1.0, 0.0, -1.0], [-1.0, 0.0, 1.0], [-1.0, 2.0, 1.0], [-1.0, 2.0, -1.0]], [1.0, 0.0, 0.0], white, FLAG_LEFT_WALL);
        mesh.quad([[1.0, 0.0, -1.0], [1.0, 0.0, 1.0], [1.0, 2.0, 1.0], [1.0, 2.0, -1.0]], [-1.0, 0.0, 0.0], white, FLAG_RIGHT_WALL);
        // the light, just under the ceiling
        let l = LIGHT_HALF_SIZE;
        mesh.quad([[-l, LIGHT_Y, -l], [l, LIGHT_Y, -l], [l, LIGHT_Y, l], [-l, LIGHT_Y, l]], [0.0, -1.0, 0.0], [1.0, 1.0, 1.0], FLAG_EMISSIVE);
        // the tall block
        mesh.block([-0.35, -0.3], [0.3, 0.3], 1.2, 0.3, white);
        mesh
    }
}

// ---------------------------------------------------------------------------
// Setup
// ---------------------------------------------------------------------------

fn uav_barrier(resource: &ID3D12Resource) -> D3D12_RESOURCE_BARRIER {
    D3D12_RESOURCE_BARRIER {
        Type: D3D12_RESOURCE_BARRIER_TYPE_UAV,
        Flags: D3D12_RESOURCE_BARRIER_FLAG_NONE,
        Anonymous: D3D12_RESOURCE_BARRIER_0 {
            UAV: std::mem::ManuallyDrop::new(D3D12_RESOURCE_UAV_BARRIER {
                pResource: unsafe { std::mem::transmute_copy(resource) },
            }),
        },
    }
}

/// Record the build of one acceleration structure; returns it. The scratch
/// buffer goes to `keep` (it must live until the build has run).
fn build_acceleration_structure(
    device: &ID3D12Device5,
    list: &ID3D12GraphicsCommandList4,
    inputs: &D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS,
    keep: &mut Vec<ID3D12Resource>,
) -> Result<ID3D12Resource> {
    let mut info = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_PREBUILD_INFO::default();
    unsafe { device.GetRaytracingAccelerationStructurePrebuildInfo(inputs, &mut info) };
    if info.ResultDataMaxSizeInBytes == 0 {
        return Err(anyhow!("the GPU rejected the acceleration structure inputs"));
    }
    let base: ID3D12Device = device.cast()?;
    let scratch = create_buffer(
        &base,
        info.ScratchDataSizeInBytes,
        D3D12_HEAP_TYPE_DEFAULT,
        D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS,
        D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
    )?;
    let result = create_buffer(
        &base,
        info.ResultDataMaxSizeInBytes,
        D3D12_HEAP_TYPE_DEFAULT,
        D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS,
        D3D12_RESOURCE_STATE_RAYTRACING_ACCELERATION_STRUCTURE,
    )?;
    unsafe {
        list.BuildRaytracingAccelerationStructure(
            &D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC {
                DestAccelerationStructureData: result.GetGPUVirtualAddress(),
                Inputs: *inputs,
                SourceAccelerationStructureData: 0,
                ScratchAccelerationStructureData: scratch.GetGPUVirtualAddress(),
            },
            None,
        );
        // The top level reads the bottom levels: make each build finish first.
        list.ResourceBarrier(&[uav_barrier(&result)]);
    }
    keep.push(scratch);
    Ok(result)
}

fn bottom_level_inputs(
    geometry: &D3D12_RAYTRACING_GEOMETRY_DESC,
) -> D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS {
    D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS {
        Type: D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL,
        Flags: D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_TRACE,
        NumDescs: 1,
        DescsLayout: D3D12_ELEMENTS_LAYOUT_ARRAY,
        Anonymous: D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS_0 {
            pGeometryDescs: geometry,
        },
    }
}

fn create_uav_texture(
    device: &ID3D12Device,
    format: DXGI_FORMAT,
    width: u32,
    height: u32,
) -> Result<ID3D12Resource> {
    let mut texture: Option<ID3D12Resource> = None;
    unsafe {
        device.CreateCommittedResource(
            &D3D12_HEAP_PROPERTIES {
                Type: D3D12_HEAP_TYPE_DEFAULT,
                ..Default::default()
            },
            D3D12_HEAP_FLAG_NONE,
            &D3D12_RESOURCE_DESC {
                Dimension: D3D12_RESOURCE_DIMENSION_TEXTURE2D,
                Width: width as u64,
                Height: height,
                DepthOrArraySize: 1,
                MipLevels: 1,
                Format: format,
                SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                Flags: D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS,
                ..Default::default()
            },
            D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
            None,
            &mut texture,
        )?;
    }
    texture.ok_or_else(|| anyhow!("CreateCommittedResource returned no texture"))
}

impl RayTracing {
    pub fn new(gfx: &mut Gfx) -> Result<RayTracing> {
        let device: ID3D12Device5 = gfx
            .device
            .cast()
            .map_err(|_| anyhow!("this Windows version has no DirectX Raytracing (ID3D12Device5)"))?;
        let list4: ID3D12GraphicsCommandList4 = gfx
            .list
            .cast()
            .map_err(|_| anyhow!("this Windows version has no DirectX Raytracing (command list 4)"))?;

        // --- geometry ------------------------------------------------------
        let mesh = BoxMesh::cornell_box();
        let vertex_buffer = create_upload_buffer(&gfx.device, &mesh.vertices)?;
        let triangle_info = create_upload_buffer(&gfx.device, &mesh.triangles)?;
        let r = SPHERE_RADIUS;
        let sphere_bounds = [D3D12_RAYTRACING_AABB {
            MinX: SPHERE_CENTER[0] - r,
            MinY: SPHERE_CENTER[1] - r,
            MinZ: SPHERE_CENTER[2] - r,
            MaxX: SPHERE_CENTER[0] + r,
            MaxY: SPHERE_CENTER[1] + r,
            MaxZ: SPHERE_CENTER[2] + r,
        }];
        let bounds_buffer = create_upload_buffer(&gfx.device, &sphere_bounds)?;

        // --- acceleration structures ----------------------------------------
        let mut keep = Vec::new();
        gfx.begin_commands()?;

        let triangles_geometry = D3D12_RAYTRACING_GEOMETRY_DESC {
            Type: D3D12_RAYTRACING_GEOMETRY_TYPE_TRIANGLES,
            Flags: D3D12_RAYTRACING_GEOMETRY_FLAG_OPAQUE,
            Anonymous: D3D12_RAYTRACING_GEOMETRY_DESC_0 {
                Triangles: D3D12_RAYTRACING_GEOMETRY_TRIANGLES_DESC {
                    Transform3x4: 0,
                    IndexFormat: DXGI_FORMAT_UNKNOWN,
                    VertexFormat: DXGI_FORMAT_R32G32B32_FLOAT,
                    IndexCount: 0,
                    VertexCount: mesh.vertices.len() as u32,
                    IndexBuffer: 0,
                    VertexBuffer: D3D12_GPU_VIRTUAL_ADDRESS_AND_STRIDE {
                        StartAddress: unsafe { vertex_buffer.GetGPUVirtualAddress() },
                        StrideInBytes: size_of::<[f32; 3]>() as u64,
                    },
                },
            },
        };
        let box_blas = build_acceleration_structure(
            &device,
            &list4,
            &bottom_level_inputs(&triangles_geometry),
            &mut keep,
        )?;

        let sphere_geometry = D3D12_RAYTRACING_GEOMETRY_DESC {
            Type: D3D12_RAYTRACING_GEOMETRY_TYPE_PROCEDURAL_PRIMITIVE_AABBS,
            Flags: D3D12_RAYTRACING_GEOMETRY_FLAG_OPAQUE,
            Anonymous: D3D12_RAYTRACING_GEOMETRY_DESC_0 {
                AABBs: D3D12_RAYTRACING_GEOMETRY_AABBS_DESC {
                    AABBCount: 1,
                    AABBs: D3D12_GPU_VIRTUAL_ADDRESS_AND_STRIDE {
                        StartAddress: unsafe { bounds_buffer.GetGPUVirtualAddress() },
                        StrideInBytes: size_of::<D3D12_RAYTRACING_AABB>() as u64,
                    },
                },
            },
        };
        let sphere_blas = build_acceleration_structure(
            &device,
            &list4,
            &bottom_level_inputs(&sphere_geometry),
            &mut keep,
        )?;

        // Two instances per box, sharing its number: the triangles (hit group
        // 0) and the sphere (hit group 1).
        let mut instances = Vec::new();
        let half = (BOXES_PER_ROW - 1) as f32 * 0.5;
        for index in 0..BOX_COUNT {
            let x = ((index % BOXES_PER_ROW) as f32 - half) * BOX_SPACING;
            let y = ((index / BOXES_PER_ROW) as f32 - half) * BOX_SPACING;
            #[rustfmt::skip]
            let transform = [
                1.0, 0.0, 0.0, x,
                0.0, 1.0, 0.0, y,
                0.0, 0.0, 1.0, 0.0,
            ];
            for (blas, hit_group) in [(&box_blas, 0u32), (&sphere_blas, 1u32)] {
                instances.push(D3D12_RAYTRACING_INSTANCE_DESC {
                    Transform: transform,
                    // InstanceID : 24, InstanceMask : 8
                    _bitfield1: index | (0xFF << 24),
                    // InstanceContributionToHitGroupIndex : 24, Flags : 8
                    _bitfield2: hit_group,
                    AccelerationStructure: unsafe { blas.GetGPUVirtualAddress() },
                });
            }
        }
        let instance_buffer = create_upload_buffer(&gfx.device, &instances)?;
        let top_level = build_acceleration_structure(
            &device,
            &list4,
            &D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS {
                Type: D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL,
                Flags: D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_TRACE,
                NumDescs: instances.len() as u32,
                DescsLayout: D3D12_ELEMENTS_LAYOUT_ARRAY,
                Anonymous: D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS_0 {
                    InstanceDescs: unsafe { instance_buffer.GetGPUVirtualAddress() },
                },
            },
            &mut keep,
        )?;
        gfx.submit_and_wait()?;
        // Built: the scratch buffers and the instance list are done with. The
        // bottom levels stay (the top level points at them), and so do their
        // inputs, which is cheap and keeps this simple.
        keep.clear();
        keep.extend([box_blas, sphere_blas, vertex_buffer, bounds_buffer]);
        drop(instance_buffer);

        // --- root signature --------------------------------------------------
        // 0: table { u0 accumulation, u1 output }   1: t0 scene
        // 2: b0 frame constants                     3: t1 per-triangle info
        let uav_range = D3D12_DESCRIPTOR_RANGE {
            RangeType: D3D12_DESCRIPTOR_RANGE_TYPE_UAV,
            NumDescriptors: 2,
            BaseShaderRegister: 0,
            RegisterSpace: 0,
            OffsetInDescriptorsFromTableStart: 0,
        };
        let root_descriptor = |kind, register| D3D12_ROOT_PARAMETER {
            ParameterType: kind,
            Anonymous: D3D12_ROOT_PARAMETER_0 {
                Descriptor: D3D12_ROOT_DESCRIPTOR {
                    ShaderRegister: register,
                    RegisterSpace: 0,
                },
            },
            ShaderVisibility: D3D12_SHADER_VISIBILITY_ALL,
        };
        let parameters = [
            D3D12_ROOT_PARAMETER {
                ParameterType: D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE,
                Anonymous: D3D12_ROOT_PARAMETER_0 {
                    DescriptorTable: D3D12_ROOT_DESCRIPTOR_TABLE {
                        NumDescriptorRanges: 1,
                        pDescriptorRanges: &uav_range,
                    },
                },
                ShaderVisibility: D3D12_SHADER_VISIBILITY_ALL,
            },
            root_descriptor(D3D12_ROOT_PARAMETER_TYPE_SRV, 0),
            root_descriptor(D3D12_ROOT_PARAMETER_TYPE_CBV, 0),
            root_descriptor(D3D12_ROOT_PARAMETER_TYPE_SRV, 1),
        ];
        let root_signature = create_root_signature(
            &gfx.device,
            &D3D12_ROOT_SIGNATURE_DESC {
                NumParameters: parameters.len() as u32,
                pParameters: parameters.as_ptr(),
                ..Default::default()
            },
        )?;

        // --- ray tracing pipeline --------------------------------------------
        let library = D3D12_DXIL_LIBRARY_DESC {
            DXILLibrary: D3D12_SHADER_BYTECODE {
                pShaderBytecode: SHADER_LIBRARY.as_ptr() as *const _,
                BytecodeLength: SHADER_LIBRARY.len(),
            },
            NumExports: 0, // all of them
            pExports: std::ptr::null_mut(),
        };
        let triangle_group = D3D12_HIT_GROUP_DESC {
            HitGroupExport: w!("TriangleHitGroup"),
            Type: D3D12_HIT_GROUP_TYPE_TRIANGLES,
            AnyHitShaderImport: PCWSTR::null(),
            ClosestHitShaderImport: w!("TriangleHit"),
            IntersectionShaderImport: PCWSTR::null(),
        };
        let sphere_group = D3D12_HIT_GROUP_DESC {
            HitGroupExport: w!("SphereHitGroup"),
            Type: D3D12_HIT_GROUP_TYPE_PROCEDURAL_PRIMITIVE,
            AnyHitShaderImport: PCWSTR::null(),
            ClosestHitShaderImport: w!("SphereHit"),
            IntersectionShaderImport: w!("SphereIntersection"),
        };
        let shader_config = D3D12_RAYTRACING_SHADER_CONFIG {
            MaxPayloadSizeInBytes: PAYLOAD_SIZE,
            MaxAttributeSizeInBytes: ATTRIBUTE_SIZE,
        };
        let global_root_signature = D3D12_GLOBAL_ROOT_SIGNATURE {
            // Borrowed, not add-ref'd: `root_signature` outlives this call.
            pGlobalRootSignature: unsafe { std::mem::transmute_copy(&root_signature) },
        };
        let pipeline_config = D3D12_RAYTRACING_PIPELINE_CONFIG {
            // The ray generation shader loops over bounces; nothing recurses.
            MaxTraceRecursionDepth: 1,
        };
        let subobject = |kind, desc: *const std::ffi::c_void| D3D12_STATE_SUBOBJECT {
            Type: kind,
            pDesc: desc,
        };
        let subobjects = [
            subobject(D3D12_STATE_SUBOBJECT_TYPE_DXIL_LIBRARY, &library as *const _ as _),
            subobject(D3D12_STATE_SUBOBJECT_TYPE_HIT_GROUP, &triangle_group as *const _ as _),
            subobject(D3D12_STATE_SUBOBJECT_TYPE_HIT_GROUP, &sphere_group as *const _ as _),
            subobject(D3D12_STATE_SUBOBJECT_TYPE_RAYTRACING_SHADER_CONFIG, &shader_config as *const _ as _),
            subobject(D3D12_STATE_SUBOBJECT_TYPE_GLOBAL_ROOT_SIGNATURE, &global_root_signature as *const _ as _),
            subobject(D3D12_STATE_SUBOBJECT_TYPE_RAYTRACING_PIPELINE_CONFIG, &pipeline_config as *const _ as _),
        ];
        let state_object: ID3D12StateObject = unsafe {
            device.CreateStateObject(&D3D12_STATE_OBJECT_DESC {
                Type: D3D12_STATE_OBJECT_TYPE_RAYTRACING_PIPELINE,
                NumSubobjects: subobjects.len() as u32,
                pSubobjects: subobjects.as_ptr(),
            })
        }
        .map_err(|e| anyhow!("the ray tracing pipeline failed to build: {e}"))?;

        // --- shader table: [ray generation] [miss, shadow miss] [two hit groups]
        let properties: ID3D12StateObjectProperties = state_object.cast()?;
        let mut table = [0u8; TABLE_SLOT * 3];
        for (offset, name) in [
            (0, w!("RayGen")),
            (TABLE_SLOT, w!("Miss")),
            (TABLE_SLOT + SHADER_ID_SIZE, w!("ShadowMiss")),
            (TABLE_SLOT * 2, w!("TriangleHitGroup")),
            (TABLE_SLOT * 2 + SHADER_ID_SIZE, w!("SphereHitGroup")),
        ] {
            let id = unsafe { properties.GetShaderIdentifier(name) };
            if id.is_null() {
                return Err(anyhow!("shader {} is missing from the library", unsafe {
                    name.display()
                }));
            }
            let id = unsafe { std::slice::from_raw_parts(id as *const u8, SHADER_ID_SIZE) };
            table[offset..offset + SHADER_ID_SIZE].copy_from_slice(id);
        }
        let shader_table = create_upload_buffer(&gfx.device, &table)?;

        // --- per-frame constants, mapped for the demo's lifetime --------------
        let constants = create_buffer(
            &gfx.device,
            256, // constant buffers come in multiples of 256 bytes
            D3D12_HEAP_TYPE_UPLOAD,
            D3D12_RESOURCE_FLAG_NONE,
            D3D12_RESOURCE_STATE_GENERIC_READ,
        )?;
        let mut constants_ptr = std::ptr::null_mut();
        unsafe { constants.Map(0, None, Some(&mut constants_ptr))? };

        let uav_heap: ID3D12DescriptorHeap = unsafe {
            gfx.device.CreateDescriptorHeap(&D3D12_DESCRIPTOR_HEAP_DESC {
                Type: D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,
                NumDescriptors: 2,
                Flags: D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE,
                ..Default::default()
            })?
        };
        let uav_size = unsafe {
            gfx.device
                .GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV)
        } as usize;

        let mut demo = RayTracing {
            list4,
            root_signature,
            state_object,
            shader_table,
            top_level,
            triangle_info,
            constants,
            constants_ptr: constants_ptr as *mut FrameConstants,
            uav_heap,
            uav_size,
            accum: None,
            output: None,
            frame_index: 0,
            _keep_alive: keep,
        };
        demo.create_targets(gfx)?;
        Ok(demo)
    }

    /// (Re)create the accumulation and output textures at the window size and
    /// start accumulating from scratch.
    fn create_targets(&mut self, gfx: &Gfx) -> Result<()> {
        let accum = create_uav_texture(&gfx.device, ACCUM_FORMAT, gfx.width, gfx.height)?;
        let output = create_uav_texture(&gfx.device, BACK_BUFFER_FORMAT, gfx.width, gfx.height)?;
        unsafe {
            let start = self.uav_heap.GetCPUDescriptorHandleForHeapStart();
            for (slot, texture) in [&accum, &output].into_iter().enumerate() {
                gfx.device.CreateUnorderedAccessView(
                    texture,
                    None::<&ID3D12Resource>,
                    None,
                    D3D12_CPU_DESCRIPTOR_HANDLE {
                        ptr: start.ptr + slot * self.uav_size,
                    },
                );
            }
        }
        self.accum = Some(accum);
        self.output = Some(output);
        self.frame_index = 0;
        Ok(())
    }
}

impl Demo for RayTracing {
    fn resized(&mut self, gfx: &mut Gfx) -> Result<()> {
        // Gfx::resize already waited for the GPU, so the old textures are free.
        self.create_targets(gfx)
    }

    fn render(&mut self, gfx: &mut Gfx) -> Result<()> {
        // The camera looks at the middle box and backs off until the whole
        // grid fits, in a wide window or a tall one.
        let aspect = gfx.width as f32 / gfx.height as f32;
        let tan_half_fov = (20.0f32).to_radians().tan();
        let grid_half = BOX_SPACING * (BOXES_PER_ROW as f32) * 0.5 + 0.2;
        let distance = grid_half / (tan_half_fov * aspect.min(1.0));
        unsafe {
            self.constants_ptr.write(FrameConstants {
                camera_position: [0.0, 1.0, 1.0 + distance],
                frame_index: self.frame_index,
                camera_right: [1.0, 0.0, 0.0],
                tan_half_fov,
                camera_up: [0.0, 1.0, 0.0],
                aspect,
                camera_forward: [0.0, 0.0, -1.0],
                boxes_per_row: BOXES_PER_ROW,
                box_spacing: BOX_SPACING,
                padding: [0.0; 3],
            });
        }

        let index = gfx.begin_frame()?;
        let back_buffer = &gfx.back_buffers[index];
        let output = self.output.as_ref().ok_or_else(|| anyhow!("no output texture"))?;
        let list = &gfx.list;
        unsafe {
            let table = self.shader_table.GetGPUVirtualAddress();
            list.SetDescriptorHeaps(&[Some(self.uav_heap.clone())]);
            list.SetComputeRootSignature(&self.root_signature);
            list.SetComputeRootDescriptorTable(0, self.uav_heap.GetGPUDescriptorHandleForHeapStart());
            list.SetComputeRootShaderResourceView(1, self.top_level.GetGPUVirtualAddress());
            list.SetComputeRootConstantBufferView(2, self.constants.GetGPUVirtualAddress());
            list.SetComputeRootShaderResourceView(3, self.triangle_info.GetGPUVirtualAddress());
            self.list4.SetPipelineState1(&self.state_object);
            self.list4.DispatchRays(&D3D12_DISPATCH_RAYS_DESC {
                RayGenerationShaderRecord: D3D12_GPU_VIRTUAL_ADDRESS_RANGE {
                    StartAddress: table,
                    SizeInBytes: SHADER_ID_SIZE as u64,
                },
                MissShaderTable: D3D12_GPU_VIRTUAL_ADDRESS_RANGE_AND_STRIDE {
                    StartAddress: table + TABLE_SLOT as u64,
                    SizeInBytes: 2 * SHADER_ID_SIZE as u64,
                    StrideInBytes: SHADER_ID_SIZE as u64,
                },
                HitGroupTable: D3D12_GPU_VIRTUAL_ADDRESS_RANGE_AND_STRIDE {
                    StartAddress: table + 2 * TABLE_SLOT as u64,
                    SizeInBytes: 2 * SHADER_ID_SIZE as u64,
                    StrideInBytes: SHADER_ID_SIZE as u64,
                },
                CallableShaderTable: Default::default(),
                Width: gfx.width,
                Height: gfx.height,
                Depth: 1,
            });

            // Show the tone-mapped image.
            list.ResourceBarrier(&[
                transition(output, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_COPY_SOURCE),
                transition(back_buffer, D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_COPY_DEST),
            ]);
            list.CopyResource(back_buffer, output);
            list.ResourceBarrier(&[
                transition(output, D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_UNORDERED_ACCESS),
                transition(back_buffer, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_PRESENT),
            ]);
        }
        gfx.end_frame()?;
        self.frame_index += 1;
        Ok(())
    }
}
