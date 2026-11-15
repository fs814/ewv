// A colorful rotating triangle (ewv's src/dx12/triangle): the shape of
// Microsoft's D3D12HelloTriangle sample. Shaders: triangle.hlsl, compiled by
// fxc at build time (CMakeLists.txt) into triangle_vs.h / triangle_ps.h.
#include "dx12.h"

#include "triangle_ps.h"
#include "triangle_vs.h"

#include <chrono>
#include <cmath>

namespace winine::dx12
{
namespace
{
struct Vertex
{
	float position[3];
	float color[4];
};

// Corners around the origin and their colors.
const float CORNERS[3][2] = {{0.0f, 0.6f}, {0.52f, -0.3f}, {-0.52f, -0.3f}};
const float COLORS[3][4]  = {{1, 0, 0, 1}, {0, 1, 0, 1}, {0, 0, 1, 1}};

class Triangle final : public Demo
{
  public:
	explicit Triangle(Gfx &gfx)
	{
		D3D12_ROOT_SIGNATURE_DESC root{};
		root.Flags     = D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;
		root_signature = create_root_signature(gfx.device.Get(), root);

		D3D12_INPUT_ELEMENT_DESC layout[] = {
		    {"POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 0, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
		    {"COLOR", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 12, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
		};
		D3D12_GRAPHICS_PIPELINE_STATE_DESC desc{};
		desc.pRootSignature                        = root_signature.Get();
		desc.VS                                    = {g_triangle_vs, sizeof g_triangle_vs};
		desc.PS                                    = {g_triangle_ps, sizeof g_triangle_ps};
		desc.RasterizerState.FillMode              = D3D12_FILL_MODE_SOLID;
		desc.RasterizerState.CullMode              = D3D12_CULL_MODE_NONE;
		desc.RasterizerState.DepthClipEnable       = TRUE;
		desc.BlendState.RenderTarget[0].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
		desc.SampleMask                            = UINT_MAX;
		desc.InputLayout                           = {layout, 2};
		desc.PrimitiveTopologyType                 = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
		desc.NumRenderTargets                      = 1;
		desc.RTVFormats[0]                         = BACK_BUFFER_FORMAT;
		desc.SampleDesc                            = {1, 0};
		check(gfx.device->CreateGraphicsPipelineState(&desc, IID_PPV_ARGS(&pipeline)), "CreateGraphicsPipelineState");

		Vertex initial[3]{};
		vertex_buffer = create_upload_buffer(gfx.device.Get(), initial, sizeof initial);
		void *mapped  = nullptr;
		check(vertex_buffer->Map(0, nullptr, &mapped), "Map");        // stays mapped
		vertices                   = static_cast<Vertex *>(mapped);
		vertex_view.BufferLocation = vertex_buffer->GetGPUVirtualAddress();
		vertex_view.SizeInBytes    = sizeof initial;
		vertex_view.StrideInBytes  = sizeof(Vertex);
	}

	void render(Gfx &gfx) override
	{
		// One turn every six seconds, kept undistorted in a non-square window.
		float seconds = std::chrono::duration<float>(std::chrono::steady_clock::now() - started).count();
		float angle   = seconds * 6.2831853f / 6.0f;
		float s = std::sin(angle), c = std::cos(angle);
		float aspect  = static_cast<float>(gfx.width) / static_cast<float>(gfx.height);
		float scale_x = aspect >= 1.0f ? 1.0f / aspect : 1.0f;
		float scale_y = aspect >= 1.0f ? 1.0f : aspect;
		for (int i = 0; i < 3; ++i)
		{
			float x = CORNERS[i][0] * c - CORNERS[i][1] * s;
			float y = CORNERS[i][0] * s + CORNERS[i][1] * c;
			Vertex v{{x * scale_x * 1.3f, y * scale_y * 1.3f, 0.0f},
			         {COLORS[i][0], COLORS[i][1], COLORS[i][2], COLORS[i][3]}};
			vertices[i] = v;
		}

		size_t          index = gfx.begin_frame();
		D3D12_VIEWPORT  viewport;
		D3D12_RECT      scissor;
		gfx.full_viewport(viewport, scissor);
		ID3D12Resource *back = gfx.back_buffers[index].Get();
		auto            rtv  = gfx.rtv(index);
		auto           *list = gfx.list.Get();
		list->SetGraphicsRootSignature(root_signature.Get());
		list->SetPipelineState(pipeline.Get());
		list->RSSetViewports(1, &viewport);
		list->RSSetScissorRects(1, &scissor);
		auto to_target = transition(back, D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_RENDER_TARGET);
		list->ResourceBarrier(1, &to_target);
		list->OMSetRenderTargets(1, &rtv, FALSE, nullptr);
		const float black[4] = {0, 0, 0, 1};
		list->ClearRenderTargetView(rtv, black, 0, nullptr);
		list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
		list->IASetVertexBuffers(0, 1, &vertex_view);
		list->DrawInstanced(3, 1, 0, 0);
		auto to_present = transition(back, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_PRESENT);
		list->ResourceBarrier(1, &to_present);
		gfx.end_frame();
	}

  private:
	ComPtr<ID3D12RootSignature> root_signature;
	ComPtr<ID3D12PipelineState> pipeline;
	ComPtr<ID3D12Resource>      vertex_buffer;
	Vertex                     *vertices = nullptr;
	D3D12_VERTEX_BUFFER_VIEW    vertex_view{};
	std::chrono::steady_clock::time_point started = std::chrono::steady_clock::now();
};
}        // namespace

std::unique_ptr<Demo> make_triangle(Gfx &gfx)
{
	return std::make_unique<Triangle>(gfx);
}
}        // namespace winine::dx12
