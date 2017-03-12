#include "shader/math.fxsub"
#include "shader/common.fxsub"
#include "shader/phase.fxsub"
#include "shader/skylighting.fxsub"

#include "../../shader/ibl.fxsub"
#include "../../shader/gbuffer.fxsub"
#include "../../shader/gbuffer_sampler.fxsub"

#define IBL_MIPMAP_LEVEL 7

texture SkySpecularMap : RENDERCOLORTARGET<int2 Dimensions={ 512, 256 }; int Miplevels=0;>;
sampler SkySpecularMapSample = sampler_state {
	texture = <SkySpecularMap>;
	MINFILTER = LINEAR; MAGFILTER = LINEAR; MIPFILTER = LINEAR;
	ADDRESSU = CLAMP; ADDRESSV = CLAMP;
};
sampler SkySpecularWrapMapSample = sampler_state {
	texture = <SkySpecularMap>;
	MINFILTER = LINEAR; MAGFILTER = LINEAR; MIPFILTER = LINEAR;
	ADDRESSU = WRAP; ADDRESSV = WRAP;
};
texture SkyDiffuseMap : RENDERCOLORTARGET<int2 Dimensions={ 512, 256 };>;
sampler SkyDiffuseMapSample = sampler_state {
	texture = <SkyDiffuseMap>;
	MINFILTER = LINEAR; MAGFILTER = LINEAR; MIPFILTER = NONE;
	ADDRESSU = CLAMP; ADDRESSV = CLAMP;
};

void ShadingMaterial(MaterialParam material, float3 worldView, out float3 diffuse, out float3 specular)
{
	float3 worldNormal = mul(material.normal, (float3x3)matViewInverse);
	float3 worldReflect = EnvironmentReflect(worldNormal, worldView);
	
	float3 V = normalize(worldView);
	float3 N = normalize(worldNormal);
	float3 R = normalize(worldReflect);
	
	float roughness = max(SmoothnessToRoughness(material.smoothness), 0.001);
	N = ComputeDiffuseDominantDir(N, V, roughness);
	R = ComputeSpecularDominantDir(N, R, roughness);

	float mipLayer = EnvironmentMip(IBL_MIPMAP_LEVEL, pow2(material.smoothness));
	float3 fresnel = EnvironmentSpecularPolynomial(worldNormal, worldView, material.smoothness, material.specular);

	float3 prefilteredDiffuse = DecodeRGBT(tex2Dlod(SkyDiffuseMapSample, float4(ComputeSphereCoord(R), 0, 0)));
	
	float3 prefilteredSpeculr0 = DecodeRGBT(tex2Dlod(SkySpecularMapSample, float4(ComputeSphereCoord(R), 0, mipLayer)));
	float3 prefilteredSpeculr1 = DecodeRGBT(tex2Dlod(SkyDiffuseMapSample, float4(ComputeSphereCoord(R), 0, 0)));
	float3 prefilteredSpeculr = 0;
	prefilteredSpeculr = lerp(prefilteredSpeculr0, prefilteredSpeculr1, roughness);
	prefilteredSpeculr = lerp(prefilteredSpeculr, prefilteredSpeculr1, pow2(1 - fresnel) * roughness);
	
	diffuse = prefilteredDiffuse;

	specular = prefilteredSpeculr * fresnel;
	specular *= step(0, dot(material.specular, 1) - 1e-5);
}

void GenSpecularMapVS(
	in float4 Position : POSITION,
	out float4 oTexcoord : TEXCOORD0,
	out float4 oPosition : POSITION)
{
	Position.xyz *= 2;
	oTexcoord = oPosition = mul(Position, matWorldViewProject);
}

float4 GenSpecularMapPS(in float4 texcoord : TEXCOORD0) : COLOR0
{
	float2 coord = texcoord.xy / texcoord.w;
	coord = PosToCoord(coord);
	coord += ViewportOffset;

	float3 normal = ComputeSphereNormal(coord);
	
	float scaling = 1000;

	ScatteringParams setting;
	setting.sunSize = mSunRadius;
	setting.sunRadiance = mSunRadiance;
	setting.mieG = mMiePhase;
	setting.mieHeight = 1.2 * scaling;
	setting.rayleighHeight = 15 * scaling;
	setting.earthRadius = 6360 * scaling;
	setting.earthAtmTopRadius = 6380 * scaling;
	setting.earthCenter = float3(0, -setting.earthRadius, 0);
	setting.waveLambdaMie = ComputeWaveLengthMie(mWaveLength, mMieColor, mMieTurbidity * scaling, 3);
	setting.waveLambdaRayleigh = ComputeWaveLengthRayleigh(mWaveLength) * mRayleightColor;

	float3 V = normalize(normal);
	float3 insctrColor = ComputeSkyInscattering(setting, CameraPosition + float3(0, scaling, 0), V, LightDirection).rgb;

	return EncodeRGBT(insctrColor);
}

void GenDiffuseMapVS(
	in float4 Position : POSITION,
	out float4 oTexcoord0 : TEXCOORD0,
	out float3 oTexcoord1 : TEXCOORD1,
	out float3 oTexcoord2 : TEXCOORD2,
	out float3 oTexcoord3 : TEXCOORD3,
	out float3 oTexcoord4 : TEXCOORD4,
	out float3 oTexcoord5 : TEXCOORD5,
	out float3 oTexcoord6 : TEXCOORD6,
	out float4 oPosition : POSITION)
{
	Position.xyz *= 2;
	oTexcoord0 = oPosition = mul(Position, matWorldViewProject);
   	oTexcoord1 = SHSamples(SkySpecularMapSample, 0);
    oTexcoord2 = SHSamples(SkySpecularMapSample, 1);
    oTexcoord3 = SHSamples(SkySpecularMapSample, 2);
    oTexcoord4 = SHSamples(SkySpecularMapSample, 3);
    oTexcoord5 = SHSamples(SkySpecularMapSample, 4);
    oTexcoord6 = SHSamples(SkySpecularMapSample, 5);
}

float4 GenDiffuseMapPS(
	in float4 texcoord0 : TEXCOORD0,
	in float3 SH0 : TEXCOORD1,
	in float3 SH1 : TEXCOORD2,
	in float3 SH2 : TEXCOORD3,
	in float3 SH3 : TEXCOORD4,
	in float3 SH4 : TEXCOORD5,
	in float3 SH5 : TEXCOORD6) : COLOR0
{
	float2 coord = texcoord0.xy / texcoord0.w;
	coord = PosToCoord(coord);
	coord += ViewportOffset;

	float3 normal = ComputeSphereNormal(coord);
	float3 irradiance = SHCreateIrradiance(normal, SH0, SH1, SH2, SH3, SH4, SH5);

	return EncodeRGBT(irradiance);
}

void EnvLightingVS(
	in float4 Position : POSITION,
	in float2 Texcoord : TEXCOORD0,
	out float4 oTexcoord : TEXCOORD0,
	out float3 oViewdir  : TEXCOORD1,
	out float4 oPosition : POSITION)
{
	oViewdir = normalize(CameraPosition - Position.xyz);
	oTexcoord = oPosition = mul(Position, matWorldViewProject);
}

void EnvLightingPS(
	in float4 texcoord : TEXCOORD0,
	in float3 viewdir  : TEXCOORD1,
	in float4 screenPosition : SV_Position,
	out float4 oColor0 : COLOR0,
	out float4 oColor1 : COLOR1)
{
	float2 coord = texcoord.xy / texcoord.w;
	coord = PosToCoord(coord);
	coord += ViewportOffset;

	float4 MRT5 = tex2Dlod(Gbuffer5Map, float4(coord, 0, 0));
	float4 MRT6 = tex2Dlod(Gbuffer6Map, float4(coord, 0, 0));
	float4 MRT7 = tex2Dlod(Gbuffer7Map, float4(coord, 0, 0));
	float4 MRT8 = tex2Dlod(Gbuffer8Map, float4(coord, 0, 0));

	MaterialParam materialAlpha;
	DecodeGbuffer(MRT5, MRT6, MRT7, MRT8, materialAlpha);
	
	float3 sum1 = materialAlpha.albedo + materialAlpha.specular;
	clip(dot(sum1, 1) - 1e-5);
	
	float4 MRT1 = tex2Dlod(Gbuffer1Map, float4(coord, 0, 0));
	float4 MRT2 = tex2Dlod(Gbuffer2Map, float4(coord, 0, 0));
	float4 MRT3 = tex2Dlod(Gbuffer3Map, float4(coord, 0, 0));
	float4 MRT4 = tex2Dlod(Gbuffer4Map, float4(coord, 0, 0));

	MaterialParam material;
	DecodeGbuffer(MRT1, MRT2, MRT3, MRT4, material);
	
	float3 V = normalize(viewdir);
	
	float3 diffuse = 0, specular = 0;
	ShadingMaterial(material, V, diffuse, specular);
	
	float3 diffuse2, specular2;
	ShadingMaterial(materialAlpha, V, diffuse2, specular2);
	
	oColor0 = EncodeYcbcr(screenPosition, diffuse, specular);
	oColor1 = EncodeYcbcr(screenPosition, diffuse2, specular2);
}

const float4 BackColor = float4(0,0,0,0);
const float4 IBLColor  = float4(0,0.5,0,0.5);

shared texture EnvLightAlphaMap : RENDERCOLORTARGET;

#define OBJECT_TEC(name, mmdpass) \
	technique name < string MMDPass = mmdpass;  string Subset="0";\
	string Script = \
		"ClearSetColor=BackColor;"\
		"RenderColorTarget=LightAlphaMap;"\
		"Clear=Color;"\
		"RenderColorTarget=LightSpecMap;"\
		"Clear=Color;"\
		"RenderColorTarget=SkySpecularMap;" \
		"Clear=Color;"\
		"Pass=GenSpecularMap;" \
		"RenderColorTarget=SkyDiffuseMap;" \
		"Clear=Color;"\
		"Pass=GenDiffuseMap;" \
		"RenderColorTarget=;" \
		"RenderColorTarget1=EnvLightAlphaMap;" \
		"ClearSetColor=IBLColor;"\
		"Clear=Color;"\
		"Pass=ImageBasedLighting;" \
	;> { \
		pass GenSpecularMap { \
			AlphaBlendEnable = false; AlphaTestEnable = false;\
			VertexShader = compile vs_3_0 GenSpecularMapVS(); \
			PixelShader  = compile ps_3_0 GenSpecularMapPS(); \
		} \
		pass GenDiffuseMap { \
			AlphaBlendEnable = false; AlphaTestEnable = false;\
			VertexShader = compile vs_3_0 GenDiffuseMapVS(); \
			PixelShader  = compile ps_3_0 GenDiffuseMapPS(); \
		} \
		pass ImageBasedLighting { \
			AlphaBlendEnable = false; AlphaTestEnable = false;\
			CullMode = CCW;\
			VertexShader = compile vs_3_0 EnvLightingVS(); \
			PixelShader  = compile ps_3_0 EnvLightingPS(); \
		} \
	}

OBJECT_TEC(MainTec0, "object")
OBJECT_TEC(MainTecBS0, "object_ss")

technique EdgeTec < string MMDPass = "edge"; > {}
technique ShadowTech < string MMDPass = "shadow";  > {}
technique ZplotTec < string MMDPass = "zplot"; > {}
technique MainTec1<string MMDPass = "object";> {}
technique MainTecBS1<string MMDPass = "object_ss";> {}