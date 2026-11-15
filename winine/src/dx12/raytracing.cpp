// A path-traced grid of Cornell boxes with DirectX Raytracing (ewv's
// src/dx12/raytracing): one Cornell box built once and instanced 3 x 3, each
// holding a procedural sphere (an intersection shader over a bounding box),
// with its own area light; frames accumulate so the image converges.
// Shaders: raytracing.hlsl, a lib_6_3 DXIL library compiled by dxc at build
// time (CMakeLists.txt) into raytracing_shaders.h.
#include "dx12.h"

#include "raytracing_shaders.h"

#include <cmath>
#include <cstring>

namespace winine::dx12
{
namespace
{
constexpr uint32_t BOXES_PER_ROW = 3;
constexpr uint32_t BOX_COUNT     = BOXES_PER_ROW * BOXES_PER_ROW;
constexpr float    BOX_SPACING   = 2.15f;        // boxes are 2 wide; the gap keeps walls apart

// Must match the constants at the top of raytracing.hlsl.
constexpr float    SPHERE_CENTER[3] = {0.42f, 0.35f, 0.35f};
constexpr float    SPHERE_RADIUS    = 0.35f;
constexpr float    LIGHT_Y          = 1.98f;
constexpr float    LIGHT_HALF_SIZE  = 0.3f;
constexpr uint32_t FLAG_EMISSIVE    = 2;
constexpr uint32_t FLAG_LEFT_WALL   = 4;
constexpr uint32_t FLAG_RIGHT_WALL  = 8;
constexpr UINT     PAYLOAD_SIZE     = 48;        // struct Payload
constexpr UINT     ATTRIBUTE_SIZE   = 12;        // struct SphereAttributes

constexpr DXGI_FORMAT ACCUM_FORMAT   = DXGI_FORMAT_R32G32B32A32_FLOAT;
constexpr size_t      SHADER_ID_SIZE = D3D12_SHADER_IDENTIFIER_SIZE_IN_BYTES;
constexpr size_t      TABLE_SLOT     = 64;        // one slot per table (the required alignment)

struct FrameConstants
{
	float    camera_position[3];
	uint32_t frame_index;
	float    camera_right[3];
	float    tan_half_fov;
	float    camera_up[3];
	float    aspect;
	float    camera_forward[3];
	uint32_t boxes_per_row;
	float    box_spacing;
	float    padding[3];
};

struct TriangleInfo
{
	float    normal[3];
	uint32_t flags;
	float    color[3];
	float    padding;
};

struct Float3
{
	float v[3];
};

// One Cornell box in its own space: x and z in -1..1, y in 0..2, open toward
// +z where the camera is.
struct BoxMesh
{
	std::vector<Float3>       vertices;
	std::vector<TriangleInfo> triangles;

	void quad(const Float3 (&corners)[4], Float3 normal, Float3 color, uint32_t flags)
	{
		for (int i : {0, 1, 2, 0, 2, 3})
		{
			vertices.push_back(corners[i]);
		}
		for (int i = 0; i < 2; ++i)
		{
			triangles.push_back({{normal.v[0], normal.v[1], normal.v[2]}, flags, {color.v[0], color.v[1], color.v[2]}, 0.0f});
		}
	}

	// An upright box standing on the floor, turned by ANGLE around y.
	void block(float cx, float cz, float hx, float hz, float height, float angle, Float3 color)
	{
		float s = std::sin(angle), c = std::cos(angle);
		auto  turn   = [&](float x, float z, float &ox, float &oz) {
            ox = x * c + z * s;
            oz = -x * s + z * c;
		};
		auto corner = [&](float sx, float sz, float y) {
			float x, z;
			turn(sx * hx, sz * hz, x, z);
			return Float3{{cx + x, y, cz + z}};
		};
		const float footprint[4][2] = {{-1, -1}, {1, -1}, {1, 1}, {-1, 1}};
		for (int i = 0; i < 4; ++i)
		{
			float ax = footprint[i][0], az = footprint[i][1];
			float bx = footprint[(i + 1) % 4][0], bz = footprint[(i + 1) % 4][1];
			float nx, nz;
			turn((ax + bx) * 0.5f, (az + bz) * 0.5f, nx, nz);
			Float3 side[4] = {corner(ax, az, 0), corner(bx, bz, 0), corner(bx, bz, height), corner(ax, az, height)};
			quad(side, {{nx, 0, nz}}, color, 0);
		}
		Float3 top[4] = {corner(-1, -1, height), corner(1, -1, height), corner(1, 1, height), corner(-1, 1, height)};
		quad(top, {{0, 1, 0}}, color, 0);
	}

	static BoxMesh cornell_box()
	{
		BoxMesh m;
		Float3  white{{0.73f, 0.73f, 0.73f}};
		// floor, ceiling, back wall
		m.quad({{{-1, 0, -1}}, {{1, 0, -1}}, {{1, 0, 1}}, {{-1, 0, 1}}}, {{0, 1, 0}}, white, 0);
		m.quad({{{-1, 2, -1}}, {{1, 2, -1}}, {{1, 2, 1}}, {{-1, 2, 1}}}, {{0, -1, 0}}, white, 0);
		m.quad({{{-1, 0, -1}}, {{1, 0, -1}}, {{1, 2, -1}}, {{-1, 2, -1}}}, {{0, 0, 1}}, white, 0);
		// left and right walls; the shader colors them per box
		m.quad({{{-1, 0, -1}}, {{-1, 0, 1}}, {{-1, 2, 1}}, {{-1, 2, -1}}}, {{1, 0, 0}}, white, FLAG_LEFT_WALL);
		m.quad({{{1, 0, -1}}, {{1, 0, 1}}, {{1, 2, 1}}, {{1, 2, -1}}}, {{-1, 0, 0}}, white, FLAG_RIGHT_WALL);
		// the light, just under the ceiling
		float l = LIGHT_HALF_SIZE;
		m.quad({{{-l, LIGHT_Y, -l}}, {{l, LIGHT_Y, -l}}, {{l, LIGHT_Y, l}}, {{-l, LIGHT_Y, l}}}, {{0, -1, 0}}, {{1, 1, 1}},
		       FLAG_EMISSIVE);
		// the tall block
		m.block(-0.35f, -0.3f, 0.3f, 0.3f, 1.2f, 0.3f, white);
		return m;
	}
};

D3D12_RESOURCE_BARRIER uav_barrier(ID3D12Resource *resource)
{
	D3D12_RESOURCE_BARRIER barrier{};
	barrier.Type          = D3D12_RESOURCE_BARRIER_TYPE_UAV;
	barrier.UAV.pResource = resource;
	return barrier;
}

// Record the build of one acceleration structure and return it; its scratch
// buffer goes to KEEP (it must live until the build has run).
ComPtr<ID3D12Resource> build_acceleration_structure(ID3D12Device5 *device, ID3D12GraphicsCommandList4 *list,
                                                    const D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS &inputs,
                                                    std::vector<ComPtr<ID3D12Resource>> &keep)
{
	D3D12_RAYTRACING_ACCELERATION_STRUCTURE_PREBUILD_INFO info{};
	device->GetRaytracingAccelerationStructurePrebuildInfo(&inputs, &info);
	if (info.ResultDataMaxSizeInBytes == 0)
	{
		throw std::runtime_error("the GPU rejected the acceleration structure inputs");
	}
	auto scratch = create_buffer(device, info.ScratchDataSizeInBytes, D3D12_HEAP_TYPE_DEFAULT,
	                             D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
	auto result  = create_buffer(device, info.ResultDataMaxSizeInBytes, D3D12_HEAP_TYPE_DEFAULT,
	                             D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS,
	                             D3D12_RESOURCE_STATE_RAYTRACING_ACCELERATION_STRUCTURE);
	D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC desc{};
	desc.DestAccelerationStructureData    = result->GetGPUVirtualAddress();
	desc.Inputs                           = inputs;
	desc.ScratchAccelerationStructureData = scratch->GetGPUVirtualAddress();
	list->BuildRaytracingAccelerationStructure(&desc, 0, nullptr);
	// The top level reads the bottom levels: make each build finish first.
	auto barrier = uav_barrier(result.Get());
	list->ResourceBarrier(1, &barrier);
	keep.push_back(scratch);
	return result;
}

D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS bottom_level_inputs(const D3D12_RAYTRACING_GEOMETRY_DESC *geometry)
{
	D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS inputs{};
	inputs.Type           = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL;
	inputs.Flags          = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_TRACE;
	inputs.NumDescs       = 1;
	inputs.DescsLayout    = D3D12_ELEMENTS_LAYOUT_ARRAY;
	inputs.pGeometryDescs = geometry;
	return inputs;
}

ComPtr<ID3D12Resource> create_uav_texture(ID3D12Device *device, DXGI_FORMAT format, uint32_t width, uint32_t height)
{
	D3D12_HEAP_PROPERTIES props{};
	props.Type = D3D12_HEAP_TYPE_DEFAULT;
	D3D12_RESOURCE_DESC desc{};
	desc.Dimension        = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
	desc.Width            = width;
	desc.Height           = height;
	desc.DepthOrArraySize = 1;
	desc.MipLevels        = 1;
	desc.Format           = format;
	desc.SampleDesc       = {1, 0};
	desc.Flags            = D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
	ComPtr<ID3D12Resource> texture;
	check(device->CreateCommittedResource(&props, D3D12_HEAP_FLAG_NONE, &desc, D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
	                                      nullptr, IID_PPV_ARGS(&texture)),
	      "CreateCommittedResource (texture)");
	return texture;
}

class RayTracing final : public Demo
{
  public:
	explicit RayTracing(Gfx &gfx)
	{
		ComPtr<ID3D12Device5> device;
		if (FAILED(gfx.device.As(&device)))
		{
			throw std::runtime_error("this Windows version has no DirectX Raytracing (ID3D12Device5)");
		}
		if (FAILED(gfx.list.As(&list4)))
		{
			throw std::runtime_error("this Windows version has no DirectX Raytracing (command list 4)");
		}

		// --- geometry ------------------------------------------------------
		BoxMesh mesh   = BoxMesh::cornell_box();
		auto vertices  = create_upload_buffer(gfx.device.Get(), mesh.vertices.data(), mesh.vertices.size() * sizeof(Float3));
		triangle_info  = create_upload_buffer(gfx.device.Get(), mesh.triangles.data(), mesh.triangles.size() * sizeof(TriangleInfo));
		float r        = SPHERE_RADIUS;
		D3D12_RAYTRACING_AABB sphere_bounds{SPHERE_CENTER[0] - r, SPHERE_CENTER[1] - r, SPHERE_CENTER[2] - r,
		                                    SPHERE_CENTER[0] + r, SPHERE_CENTER[1] + r, SPHERE_CENTER[2] + r};
		auto bounds = create_upload_buffer(gfx.device.Get(), &sphere_bounds, sizeof sphere_bounds);

		// --- acceleration structures ----------------------------------------
		std::vector<ComPtr<ID3D12Resource>> keep;
		gfx.begin_commands();

		D3D12_RAYTRACING_GEOMETRY_DESC triangles{};
		triangles.Type                                 = D3D12_RAYTRACING_GEOMETRY_TYPE_TRIANGLES;
		triangles.Flags                                = D3D12_RAYTRACING_GEOMETRY_FLAG_OPAQUE;
		triangles.Triangles.VertexFormat               = DXGI_FORMAT_R32G32B32_FLOAT;
		triangles.Triangles.VertexCount                = static_cast<UINT>(mesh.vertices.size());
		triangles.Triangles.VertexBuffer.StartAddress  = vertices->GetGPUVirtualAddress();
		triangles.Triangles.VertexBuffer.StrideInBytes = sizeof(Float3);
		auto triangles_inputs = bottom_level_inputs(&triangles);
		auto box_blas         = build_acceleration_structure(device.Get(), list4.Get(), triangles_inputs, keep);

		D3D12_RAYTRACING_GEOMETRY_DESC sphere{};
		sphere.Type                       = D3D12_RAYTRACING_GEOMETRY_TYPE_PROCEDURAL_PRIMITIVE_AABBS;
		sphere.Flags                      = D3D12_RAYTRACING_GEOMETRY_FLAG_OPAQUE;
		sphere.AABBs.AABBCount            = 1;
		sphere.AABBs.AABBs.StartAddress   = bounds->GetGPUVirtualAddress();
		sphere.AABBs.AABBs.StrideInBytes  = sizeof(D3D12_RAYTRACING_AABB);
		auto sphere_inputs = bottom_level_inputs(&sphere);
		auto sphere_blas   = build_acceleration_structure(device.Get(), list4.Get(), sphere_inputs, keep);

		// Two instances per box, sharing its number: the triangles (hit group
		// 0) and the sphere (hit group 1).
		std::vector<D3D12_RAYTRACING_INSTANCE_DESC> instances;
		float half = (BOXES_PER_ROW - 1) * 0.5f;
		for (uint32_t index = 0; index < BOX_COUNT; ++index)
		{
			float x = (static_cast<float>(index % BOXES_PER_ROW) - half) * BOX_SPACING;
			float y = (static_cast<float>(index / BOXES_PER_ROW) - half) * BOX_SPACING;
			for (uint32_t hit_group : {0u, 1u})
			{
				D3D12_RAYTRACING_INSTANCE_DESC instance{};
				float transform[3][4] = {{1, 0, 0, x}, {0, 1, 0, y}, {0, 0, 1, 0}};
				std::memcpy(instance.Transform, transform, sizeof transform);
				instance.InstanceID                          = index;
				instance.InstanceMask                        = 0xFF;
				instance.InstanceContributionToHitGroupIndex = hit_group;
				instance.AccelerationStructure = (hit_group ? sphere_blas : box_blas)->GetGPUVirtualAddress();
				instances.push_back(instance);
			}
		}
		auto instance_buffer = create_upload_buffer(gfx.device.Get(), instances.data(),
		                                            instances.size() * sizeof(D3D12_RAYTRACING_INSTANCE_DESC));
		D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS top{};
		top.Type          = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL;
		top.Flags         = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_TRACE;
		top.NumDescs      = static_cast<UINT>(instances.size());
		top.DescsLayout   = D3D12_ELEMENTS_LAYOUT_ARRAY;
		top.InstanceDescs = instance_buffer->GetGPUVirtualAddress();
		top_level         = build_acceleration_structure(device.Get(), list4.Get(), top, keep);
		gfx.submit_and_wait();
		// Built: the scratch buffers and the instance list are done with; the
		// bottom levels stay (the top level points at them), and their inputs.
		keep.clear();
		keep_alive = {box_blas, sphere_blas, vertices, bounds};

		// --- root signature --------------------------------------------------
		// 0: table { u0 accumulation, u1 output }   1: t0 scene
		// 2: b0 frame constants                     3: t1 per-triangle info
		D3D12_DESCRIPTOR_RANGE uav_range{D3D12_DESCRIPTOR_RANGE_TYPE_UAV, 2, 0, 0, 0};
		D3D12_ROOT_PARAMETER   parameters[4]{};
		parameters[0].ParameterType                       = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
		parameters[0].DescriptorTable.NumDescriptorRanges = 1;
		parameters[0].DescriptorTable.pDescriptorRanges   = &uav_range;
		parameters[1].ParameterType                       = D3D12_ROOT_PARAMETER_TYPE_SRV;
		parameters[1].Descriptor.ShaderRegister           = 0;
		parameters[2].ParameterType                       = D3D12_ROOT_PARAMETER_TYPE_CBV;
		parameters[2].Descriptor.ShaderRegister           = 0;
		parameters[3].ParameterType                       = D3D12_ROOT_PARAMETER_TYPE_SRV;
		parameters[3].Descriptor.ShaderRegister           = 1;
		for (auto &p : parameters)
		{
			p.ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
		}
		D3D12_ROOT_SIGNATURE_DESC root{};
		root.NumParameters = 4;
		root.pParameters   = parameters;
		root_signature     = create_root_signature(gfx.device.Get(), root);

		// --- ray tracing pipeline --------------------------------------------
		D3D12_DXIL_LIBRARY_DESC library{};
		library.DXILLibrary = {g_raytracing_shaders, sizeof g_raytracing_shaders};        // all exports
		D3D12_HIT_GROUP_DESC triangle_group{};
		triangle_group.HitGroupExport         = L"TriangleHitGroup";
		triangle_group.Type                   = D3D12_HIT_GROUP_TYPE_TRIANGLES;
		triangle_group.ClosestHitShaderImport = L"TriangleHit";
		D3D12_HIT_GROUP_DESC sphere_group{};
		sphere_group.HitGroupExport           = L"SphereHitGroup";
		sphere_group.Type                     = D3D12_HIT_GROUP_TYPE_PROCEDURAL_PRIMITIVE;
		sphere_group.ClosestHitShaderImport   = L"SphereHit";
		sphere_group.IntersectionShaderImport = L"SphereIntersection";
		D3D12_RAYTRACING_SHADER_CONFIG   shader_config{PAYLOAD_SIZE, ATTRIBUTE_SIZE};
		D3D12_GLOBAL_ROOT_SIGNATURE      global_root{root_signature.Get()};
		D3D12_RAYTRACING_PIPELINE_CONFIG pipeline_config{1};        // the ray generation shader loops; nothing recurses
		D3D12_STATE_SUBOBJECT            subobjects[] = {
            {D3D12_STATE_SUBOBJECT_TYPE_DXIL_LIBRARY, &library},
            {D3D12_STATE_SUBOBJECT_TYPE_HIT_GROUP, &triangle_group},
            {D3D12_STATE_SUBOBJECT_TYPE_HIT_GROUP, &sphere_group},
            {D3D12_STATE_SUBOBJECT_TYPE_RAYTRACING_SHADER_CONFIG, &shader_config},
            {D3D12_STATE_SUBOBJECT_TYPE_GLOBAL_ROOT_SIGNATURE, &global_root},
            {D3D12_STATE_SUBOBJECT_TYPE_RAYTRACING_PIPELINE_CONFIG, &pipeline_config},
        };
		D3D12_STATE_OBJECT_DESC state_desc{D3D12_STATE_OBJECT_TYPE_RAYTRACING_PIPELINE, _countof(subobjects), subobjects};
		HRESULT hr = device->CreateStateObject(&state_desc, IID_PPV_ARGS(&state_object));
		if (FAILED(hr))
		{
			throw HResultError(hr, "the ray tracing pipeline failed to build");
		}

		// --- shader table: [ray generation] [miss, shadow miss] [two hit groups]
		ComPtr<ID3D12StateObjectProperties> properties;
		check(state_object.As(&properties), "ID3D12StateObjectProperties");
		uint8_t table[TABLE_SLOT * 3]{};
		struct
		{
			size_t         offset;
			const wchar_t *name;
		} entries[] = {
		    {0, L"RayGen"},
		    {TABLE_SLOT, L"Miss"},
		    {TABLE_SLOT + SHADER_ID_SIZE, L"ShadowMiss"},
		    {TABLE_SLOT * 2, L"TriangleHitGroup"},
		    {TABLE_SLOT * 2 + SHADER_ID_SIZE, L"SphereHitGroup"},
		};
		for (auto &entry : entries)
		{
			void *id = properties->GetShaderIdentifier(entry.name);
			if (!id)
			{
				throw std::runtime_error("shader " + narrow(entry.name) + " is missing from the library");
			}
			std::memcpy(table + entry.offset, id, SHADER_ID_SIZE);
		}
		shader_table = create_upload_buffer(gfx.device.Get(), table, sizeof table);

		// --- per-frame constants, mapped for the demo's lifetime --------------
		constants = create_buffer(gfx.device.Get(), 256, D3D12_HEAP_TYPE_UPLOAD, D3D12_RESOURCE_FLAG_NONE,
		                          D3D12_RESOURCE_STATE_GENERIC_READ);
		void *mapped = nullptr;
		check(constants->Map(0, nullptr, &mapped), "Map");
		constants_ptr = static_cast<FrameConstants *>(mapped);

		D3D12_DESCRIPTOR_HEAP_DESC heap{};
		heap.Type           = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
		heap.NumDescriptors = 2;
		heap.Flags          = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
		check(gfx.device->CreateDescriptorHeap(&heap, IID_PPV_ARGS(&uav_heap)), "CreateDescriptorHeap");
		uav_size = gfx.device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);

		create_targets(gfx);
	}

	void resized(Gfx &gfx) override
	{
		// Gfx::resize already waited for the GPU, so the old textures are free.
		create_targets(gfx);
	}

	void render(Gfx &gfx) override
	{
		// Look at the middle box and back off until the whole grid fits.
		float aspect       = static_cast<float>(gfx.width) / static_cast<float>(gfx.height);
		float tan_half_fov = std::tan(20.0f * 3.14159265f / 180.0f);
		float grid_half    = BOX_SPACING * BOXES_PER_ROW * 0.5f + 0.2f;
		float distance     = grid_half / (tan_half_fov * (aspect < 1.0f ? aspect : 1.0f));
		*constants_ptr     = FrameConstants{{0, 1, 1 + distance}, frame_index, {1, 0, 0}, tan_half_fov,
                                        {0, 1, 0},          aspect,      {0, 0, -1}, BOXES_PER_ROW,
                                        BOX_SPACING,        {0, 0, 0}};

		size_t          index = gfx.begin_frame();
		ID3D12Resource *back  = gfx.back_buffers[index].Get();
		auto           *list  = gfx.list.Get();
		D3D12_GPU_VIRTUAL_ADDRESS table = shader_table->GetGPUVirtualAddress();
		ID3D12DescriptorHeap *heaps[] = {uav_heap.Get()};
		list->SetDescriptorHeaps(1, heaps);
		list->SetComputeRootSignature(root_signature.Get());
		list->SetComputeRootDescriptorTable(0, uav_heap->GetGPUDescriptorHandleForHeapStart());
		list->SetComputeRootShaderResourceView(1, top_level->GetGPUVirtualAddress());
		list->SetComputeRootConstantBufferView(2, constants->GetGPUVirtualAddress());
		list->SetComputeRootShaderResourceView(3, triangle_info->GetGPUVirtualAddress());
		list4->SetPipelineState1(state_object.Get());
		D3D12_DISPATCH_RAYS_DESC rays{};
		rays.RayGenerationShaderRecord = {table, SHADER_ID_SIZE};
		rays.MissShaderTable           = {table + TABLE_SLOT, 2 * SHADER_ID_SIZE, SHADER_ID_SIZE};
		rays.HitGroupTable             = {table + 2 * TABLE_SLOT, 2 * SHADER_ID_SIZE, SHADER_ID_SIZE};
		rays.Width                     = gfx.width;
		rays.Height                    = gfx.height;
		rays.Depth                     = 1;
		list4->DispatchRays(&rays);

		// Show the tone-mapped image.
		D3D12_RESOURCE_BARRIER before[] = {
		    transition(output.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_COPY_SOURCE),
		    transition(back, D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_COPY_DEST),
		};
		list->ResourceBarrier(2, before);
		list->CopyResource(back, output.Get());
		D3D12_RESOURCE_BARRIER after[] = {
		    transition(output.Get(), D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_UNORDERED_ACCESS),
		    transition(back, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_PRESENT),
		};
		list->ResourceBarrier(2, after);
		gfx.end_frame();
		++frame_index;
	}

  private:
	// (Re)create the accumulation and output textures at the window size and
	// start accumulating from scratch.
	void create_targets(Gfx &gfx)
	{
		accum  = create_uav_texture(gfx.device.Get(), ACCUM_FORMAT, gfx.width, gfx.height);
		output = create_uav_texture(gfx.device.Get(), BACK_BUFFER_FORMAT, gfx.width, gfx.height);
		D3D12_CPU_DESCRIPTOR_HANDLE start = uav_heap->GetCPUDescriptorHandleForHeapStart();
		ID3D12Resource             *targets[] = {accum.Get(), output.Get()};
		for (size_t slot = 0; slot < 2; ++slot)
		{
			D3D12_CPU_DESCRIPTOR_HANDLE handle{start.ptr + slot * uav_size};
			gfx.device->CreateUnorderedAccessView(targets[slot], nullptr, nullptr, handle);
		}
		frame_index = 0;
	}

	ComPtr<ID3D12GraphicsCommandList4>  list4;
	ComPtr<ID3D12RootSignature>         root_signature;
	ComPtr<ID3D12StateObject>           state_object;
	ComPtr<ID3D12Resource>              shader_table, top_level, triangle_info, constants, accum, output;
	FrameConstants                     *constants_ptr = nullptr;
	ComPtr<ID3D12DescriptorHeap>        uav_heap;
	size_t                              uav_size    = 0;
	uint32_t                            frame_index = 0;
	std::vector<ComPtr<ID3D12Resource>> keep_alive;        // bottom levels and their inputs
};
}        // namespace

std::unique_ptr<Demo> make_raytracing(Gfx &gfx)
{
	return std::make_unique<RayTracing>(gfx);
}
}        // namespace winine::dx12
