// The ray tracing demo's DXR shader library (lib_6_3), copied from ewv's
// src/dx12/raytracing/shaders.hlsl. CMakeLists.txt compiles it with dxc into
// raytracing_shaders.h; see raytracing.cpp for the scene, the pipeline and the
// constants that must match the ones here.
//
// A path tracer for a grid of Cornell boxes. The ray generation shader traces
// each path iteratively (no recursion): at every bounce it adds direct light
// from the hit box's ceiling light with a shadow ray, then continues in a
// cosine-weighted direction. Frames accumulate into gAccum, so the picture
// starts noisy and converges.

#define FLAG_HIT 1u
#define FLAG_EMISSIVE 2u
#define FLAG_LEFT_WALL 4u
#define FLAG_RIGHT_WALL 8u

#define MAX_BOUNCES 3
#define PI 3.14159265f

// Must match SPHERE_CENTER / SPHERE_RADIUS / LIGHT_* in mod.rs.
static const float3 kSphereCenter = float3(0.42f, 0.35f, 0.35f);
static const float kSphereRadius = 0.35f;
static const float kLightY = 1.98f;
static const float kLightHalfSize = 0.3f;
static const float3 kLightColor = float3(22.0f, 19.0f, 14.0f);
static const float3 kSky = float3(0.01f, 0.012f, 0.02f);

struct FrameConstants {
    float3 cameraPosition;
    uint frameIndex;
    float3 cameraRight;
    float tanHalfFov;
    float3 cameraUp;
    float aspect;
    float3 cameraForward;
    uint boxesPerRow;
    float boxSpacing;
    float3 padding;
};

struct TriangleInfo {
    float3 normal;
    uint flags;
    float3 color;
    float padding;
};

struct Payload {
    float3 position;
    float hitT;
    float3 normal;
    uint flags;
    float3 color;
    uint instance;
};

struct ShadowPayload {
    float visible;
};

struct SphereAttributes {
    float3 normal;
};

ConstantBuffer<FrameConstants> gFrame : register(b0);
RaytracingAccelerationStructure gScene : register(t0);
StructuredBuffer<TriangleInfo> gTriangles : register(t1);
RWTexture2D<float4> gAccum : register(u0);
RWTexture2D<float4> gOutput : register(u1);

// PCG hash: one stream per pixel and frame.
uint NextRandom(inout uint state) {
    state = state * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

float Random(inout uint state) {
    return NextRandom(state) * (1.0f / 4294967296.0f);
}

float3 CosineSampleHemisphere(float3 n, float u1, float u2) {
    float r = sqrt(u1);
    float phi = 2.0f * PI * u2;
    float3 up = abs(n.y) < 0.99f ? float3(0, 1, 0) : float3(1, 0, 0);
    float3 tangent = normalize(cross(up, n));
    float3 bitangent = cross(n, tangent);
    return normalize(tangent * (r * cos(phi)) + bitangent * (r * sin(phi)) + n * sqrt(1.0f - u1));
}

// Where box number `instance` sits in the grid (its floor center).
float3 BoxOrigin(uint instance) {
    float half = (gFrame.boxesPerRow - 1) * 0.5f;
    float column = instance % gFrame.boxesPerRow;
    float row = instance / gFrame.boxesPerRow;
    return float3((column - half) * gFrame.boxSpacing, (row - half) * gFrame.boxSpacing, 0.0f);
}

// The two colored walls: the classic red and green in the middle box, a
// different pair in each of the others.
float3 WallColor(uint instance, bool left) {
    uint middle = (gFrame.boxesPerRow * gFrame.boxesPerRow) / 2;
    if (instance == middle) {
        return left ? float3(0.75f, 0.1f, 0.1f) : float3(0.1f, 0.7f, 0.12f);
    }
    float hue = instance * 0.137f + (left ? 0.0f : 0.45f);
    return 0.12f + 0.63f * (0.5f + 0.5f * cos(2.0f * PI * (hue + float3(0.0f, 0.33f, 0.67f))));
}

[shader("raygeneration")]
void RayGen() {
    uint2 pixel = DispatchRaysIndex().xy;
    uint2 size = DispatchRaysDimensions().xy;

    uint rng = pixel.x * 1973u + pixel.y * 9277u + gFrame.frameIndex * 26699u;
    NextRandom(rng);

    float2 jitter = float2(Random(rng), Random(rng));
    float2 ndc = (pixel + jitter) / float2(size) * 2.0f - 1.0f;
    ndc.y = -ndc.y;

    float3 origin = gFrame.cameraPosition;
    float3 direction = normalize(gFrame.cameraForward
                                 + ndc.x * gFrame.aspect * gFrame.tanHalfFov * gFrame.cameraRight
                                 + ndc.y * gFrame.tanHalfFov * gFrame.cameraUp);

    float3 throughput = float3(1, 1, 1);
    float3 radiance = float3(0, 0, 0);

    for (int bounce = 0; bounce < MAX_BOUNCES; bounce++) {
        RayDesc ray;
        ray.Origin = origin;
        ray.Direction = direction;
        ray.TMin = 0.001f;
        ray.TMax = 10000.0f;

        Payload payload;
        payload.position = float3(0, 0, 0);
        payload.hitT = 0;
        payload.normal = float3(0, 0, 0);
        payload.flags = 0;
        payload.color = float3(0, 0, 0);
        payload.instance = 0;
        TraceRay(gScene, RAY_FLAG_NONE, 0xFF, 0, 1, 0, ray, payload);

        if ((payload.flags & FLAG_HIT) == 0) {
            radiance += throughput * kSky;
            break;
        }
        if ((payload.flags & FLAG_EMISSIVE) != 0) {
            // Later bounces get the light from the shadow ray below; counting
            // it here too would add it twice.
            if (bounce == 0) {
                radiance += throughput * kLightColor;
            }
            break;
        }

        float3 normal = payload.normal;
        if (dot(normal, direction) > 0.0f) {
            normal = -normal; // the walls are single quads, lit from both sides
        }
        throughput *= payload.color;

        // Direct light: a random point on this box's ceiling light.
        float3 lightPoint = BoxOrigin(payload.instance)
            + float3((Random(rng) * 2.0f - 1.0f) * kLightHalfSize, kLightY,
                     (Random(rng) * 2.0f - 1.0f) * kLightHalfSize);
        float3 toLight = lightPoint - payload.position;
        float distance2 = dot(toLight, toLight);
        float distance = sqrt(distance2);
        toLight /= distance;
        float cosSurface = dot(normal, toLight);
        float cosLight = toLight.y; // the light faces straight down
        if (cosSurface > 0.0f && cosLight > 0.0f) {
            RayDesc shadowRay;
            shadowRay.Origin = payload.position + normal * 0.001f;
            shadowRay.Direction = toLight;
            shadowRay.TMin = 0.0f;
            shadowRay.TMax = distance - 0.01f;

            ShadowPayload shadow;
            shadow.visible = 0.0f;
            TraceRay(gScene,
                     RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH | RAY_FLAG_SKIP_CLOSEST_HIT_SHADER,
                     0xFF, 0, 1, 1, shadowRay, shadow);

            float lightArea = 4.0f * kLightHalfSize * kLightHalfSize;
            radiance += throughput * kLightColor * shadow.visible
                * (cosSurface * cosLight * lightArea / (PI * distance2));
        }

        origin = payload.position + normal * 0.001f;
        direction = CosineSampleHemisphere(normal, Random(rng), Random(rng));
    }

    radiance = min(radiance, float3(8, 8, 8)); // tame fireflies

    float3 average = radiance;
    if (gFrame.frameIndex > 0) {
        float n = gFrame.frameIndex;
        average = (gAccum[pixel].rgb * n + radiance) / (n + 1.0f);
    }
    gAccum[pixel] = float4(average, 1.0f);

    float3 mapped = average / (1.0f + average);
    gOutput[pixel] = float4(pow(mapped, 1.0f / 2.2f), 1.0f);
}

[shader("miss")]
void Miss(inout Payload payload) {
    payload.flags = 0;
}

[shader("miss")]
void ShadowMiss(inout ShadowPayload payload) {
    payload.visible = 1.0f;
}

[shader("closesthit")]
void TriangleHit(inout Payload payload, in BuiltInTriangleIntersectionAttributes attributes) {
    TriangleInfo info = gTriangles[PrimitiveIndex()];
    payload.hitT = RayTCurrent();
    payload.position = WorldRayOrigin() + WorldRayDirection() * RayTCurrent();
    payload.normal = info.normal; // instances are only translated
    payload.flags = info.flags | FLAG_HIT;
    payload.instance = InstanceID();
    payload.color = info.color;
    if ((info.flags & FLAG_LEFT_WALL) != 0) {
        payload.color = WallColor(InstanceID(), true);
    } else if ((info.flags & FLAG_RIGHT_WALL) != 0) {
        payload.color = WallColor(InstanceID(), false);
    }
}

// The sphere is not triangles: its bottom-level structure holds one bounding
// box, and this shader finds where the ray enters the sphere inside it.
[shader("intersection")]
void SphereIntersection() {
    float3 origin = ObjectRayOrigin() - kSphereCenter;
    float3 direction = ObjectRayDirection();
    float a = dot(direction, direction);
    float b = dot(origin, direction);
    float c = dot(origin, origin) - kSphereRadius * kSphereRadius;
    float discriminant = b * b - a * c;
    if (discriminant < 0.0f) {
        return;
    }
    float root = sqrt(discriminant);
    float tNear = (-b - root) / a;
    float tFar = (-b + root) / a;

    SphereAttributes attributes;
    attributes.normal = normalize(origin + direction * tNear);
    if (!ReportHit(tNear, 0, attributes)) {
        attributes.normal = normalize(origin + direction * tFar);
        ReportHit(tFar, 0, attributes);
    }
}

[shader("closesthit")]
void SphereHit(inout Payload payload, in SphereAttributes attributes) {
    payload.hitT = RayTCurrent();
    payload.position = WorldRayOrigin() + WorldRayDirection() * RayTCurrent();
    payload.normal = attributes.normal;
    payload.flags = FLAG_HIT;
    payload.instance = InstanceID();
    payload.color = float3(0.85f, 0.85f, 0.85f);
}
