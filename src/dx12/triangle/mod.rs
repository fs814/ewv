//! A colorful rotating triangle: the Direct3D 12 counterpart of appine's
//! Metal triangle demo (Apple's "Drawing a triangle with Metal 4"), following
//! the shape of Microsoft's D3D12HelloTriangle sample. See README.md here.

use super::*;
use std::time::Instant;
use windows::Win32::Graphics::Direct3D::Fxc::D3DCompile;
use windows::core::{PCSTR, s};

const SHADERS: &str = include_str!("shaders.hlsl");

#[repr(C)]
#[derive(Clone, Copy)]
struct Vertex {
    position: [f32; 3],
    color: [f32; 4],
}

/// Triangle corners around the origin (unit-ish circle) and their colors.
const CORNERS: [([f32; 2], [f32; 4]); 3] = [
    ([0.0, 0.6], [1.0, 0.0, 0.0, 1.0]),
    ([0.52, -0.3], [0.0, 1.0, 0.0, 1.0]),
    ([-0.52, -0.3], [0.0, 0.0, 1.0, 1.0]),
];

pub struct Triangle {
    root_signature: ID3D12RootSignature,
    pipeline: ID3D12PipelineState,
    _vertex_buffer: ID3D12Resource,
    /// The vertex buffer stays mapped; three vertices are rewritten per frame.
    vertices: *mut Vertex,
    vertex_view: D3D12_VERTEX_BUFFER_VIEW,
    started: Instant,
}

fn compile(entry: PCSTR, target: PCSTR) -> Result<ID3DBlob> {
    let mut code = None;
    let mut errors = None;
    unsafe {
        D3DCompile(
            SHADERS.as_ptr() as *const _,
            SHADERS.len(),
            s!("triangle/shaders.hlsl"),
            None,
            None,
            entry,
            target,
            0,
            0,
            &mut code,
            Some(&mut errors),
        )
        .map_err(|e| anyhow!("triangle shaders failed to compile: {e} {}", blob_text(&errors)))?;
    }
    code.ok_or_else(|| anyhow!("triangle shaders: no bytecode"))
}

fn bytecode(blob: &ID3DBlob) -> D3D12_SHADER_BYTECODE {
    unsafe {
        D3D12_SHADER_BYTECODE {
            pShaderBytecode: blob.GetBufferPointer(),
            BytecodeLength: blob.GetBufferSize(),
        }
    }
}

impl Triangle {
    pub fn new(gfx: &mut Gfx) -> Result<Triangle> {
        let device = &gfx.device;
        let root_signature = create_root_signature(
            device,
            &D3D12_ROOT_SIGNATURE_DESC {
                Flags: D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT,
                ..Default::default()
            },
        )?;

        let vs = compile(s!("VSMain"), s!("vs_5_0"))?;
        let ps = compile(s!("PSMain"), s!("ps_5_0"))?;

        let input_layout = [
            D3D12_INPUT_ELEMENT_DESC {
                SemanticName: s!("POSITION"),
                Format: DXGI_FORMAT_R32G32B32_FLOAT,
                AlignedByteOffset: 0,
                InputSlotClass: D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA,
                ..Default::default()
            },
            D3D12_INPUT_ELEMENT_DESC {
                SemanticName: s!("COLOR"),
                Format: DXGI_FORMAT_R32G32B32A32_FLOAT,
                AlignedByteOffset: 12,
                InputSlotClass: D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA,
                ..Default::default()
            },
        ];

        let mut desc = D3D12_GRAPHICS_PIPELINE_STATE_DESC {
            // Borrowed, not add-ref'd: `root_signature` outlives this call.
            pRootSignature: unsafe { std::mem::transmute_copy(&root_signature) },
            VS: bytecode(&vs),
            PS: bytecode(&ps),
            RasterizerState: D3D12_RASTERIZER_DESC {
                FillMode: D3D12_FILL_MODE_SOLID,
                CullMode: D3D12_CULL_MODE_NONE,
                DepthClipEnable: true.into(),
                ..Default::default()
            },
            SampleMask: u32::MAX,
            InputLayout: D3D12_INPUT_LAYOUT_DESC {
                pInputElementDescs: input_layout.as_ptr(),
                NumElements: input_layout.len() as u32,
            },
            PrimitiveTopologyType: D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE,
            NumRenderTargets: 1,
            SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
            ..Default::default()
        };
        desc.BlendState.RenderTarget[0].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL.0 as u8;
        desc.RTVFormats[0] = BACK_BUFFER_FORMAT;
        let pipeline: ID3D12PipelineState = unsafe { device.CreateGraphicsPipelineState(&desc)? };

        let initial = [Vertex { position: [0.0; 3], color: [0.0; 4] }; 3];
        let vertex_buffer = create_upload_buffer(device, &initial)?;
        let mut mapped = std::ptr::null_mut();
        unsafe { vertex_buffer.Map(0, None, Some(&mut mapped))? };
        let vertex_view = D3D12_VERTEX_BUFFER_VIEW {
            BufferLocation: unsafe { vertex_buffer.GetGPUVirtualAddress() },
            SizeInBytes: size_of_val(&initial) as u32,
            StrideInBytes: size_of::<Vertex>() as u32,
        };

        Ok(Triangle {
            root_signature,
            pipeline,
            _vertex_buffer: vertex_buffer,
            vertices: mapped as *mut Vertex,
            vertex_view,
            started: Instant::now(),
        })
    }
}

impl Demo for Triangle {
    fn render(&mut self, gfx: &mut Gfx) -> Result<()> {
        // One turn every six seconds, kept undistorted in a non-square window.
        let angle = self.started.elapsed().as_secs_f32() * std::f32::consts::TAU / 6.0;
        let (sin, cos) = angle.sin_cos();
        let aspect = gfx.width as f32 / gfx.height as f32;
        let (scale_x, scale_y) = if aspect >= 1.0 { (1.0 / aspect, 1.0) } else { (1.0, aspect) };
        for (i, (p, color)) in CORNERS.iter().enumerate() {
            let x = p[0] * cos - p[1] * sin;
            let y = p[0] * sin + p[1] * cos;
            unsafe {
                self.vertices.add(i).write(Vertex {
                    position: [x * scale_x * 1.3, y * scale_y * 1.3, 0.0],
                    color: *color,
                });
            }
        }

        let index = gfx.begin_frame()?;
        let (viewport, scissor) = gfx.full_viewport();
        let back_buffer = &gfx.back_buffers[index];
        let rtv = gfx.rtv(index);
        let list = &gfx.list;
        unsafe {
            list.SetGraphicsRootSignature(&self.root_signature);
            list.SetPipelineState(&self.pipeline);
            list.RSSetViewports(&[viewport]);
            list.RSSetScissorRects(&[scissor]);
            list.ResourceBarrier(&[transition(
                back_buffer,
                D3D12_RESOURCE_STATE_PRESENT,
                D3D12_RESOURCE_STATE_RENDER_TARGET,
            )]);
            list.OMSetRenderTargets(1, Some(&rtv), false, None);
            list.ClearRenderTargetView(rtv, &[0.0, 0.0, 0.0, 1.0], None);
            list.IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            list.IASetVertexBuffers(0, Some(&[self.vertex_view]));
            list.DrawInstanced(3, 1, 0, 0);
            list.ResourceBarrier(&[transition(
                back_buffer,
                D3D12_RESOURCE_STATE_RENDER_TARGET,
                D3D12_RESOURCE_STATE_PRESENT,
            )]);
        }
        gfx.end_frame()
    }
}
