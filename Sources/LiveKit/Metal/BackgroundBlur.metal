#include <metal_stdlib>
using namespace metal;

kernel void maskedBlur(texture2d<float, access::sample> lumaTexture [[texture(0)]],
                       texture2d<float, access::sample> chromaTexture [[texture(1)]],
                       texture2d<float, access::sample> maskTexture [[texture(2)]],
                       texture2d<float, access::write> outputLumaTexture [[texture(3)]],
                       texture2d<float, access::write> outputChromaTexture [[texture(4)]],
                       constant float &blurRadius [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outputLumaTexture.get_width() || gid.y >= outputLumaTexture.get_height()) {
        return;
    }
    
    constexpr sampler textureSampler(filter::linear, address::clamp_to_edge);
    float2 textureCoord = float2(gid) / float2(outputLumaTexture.get_width(), outputLumaTexture.get_height());
    
    float maskValue = maskTexture.sample(textureSampler, textureCoord).r;

    float originalLuma = lumaTexture.sample(textureSampler, textureCoord).r;
    float2 originalChroma = chromaTexture.sample(textureSampler, textureCoord).rg;
    
    
    if (maskValue > 0.95) {
        outputLumaTexture.write(float4(originalLuma, 0.0, 0.0, 0.0), gid);
        
        uint2 chromaCoord = uint2(gid.x / 2, gid.y / 2);
        if (chromaCoord.x < outputChromaTexture.get_width() &&
            chromaCoord.y < outputChromaTexture.get_height()) {
            outputChromaTexture.write(float4(originalChroma.x, originalChroma.y, 0.0, 0.0), chromaCoord);
        }
        return;
    }
    
    float sigma = blurRadius;
    float twoSigmaSq = 2.0 * sigma * sigma;
    
    float2 texelSize = float2(1.0 / float(outputLumaTexture.get_width()), 
                             1.0 / float(outputLumaTexture.get_height()));
    
    const int MAX_RADIUS = 4;
    int radius = min(MAX_RADIUS, int(ceil(sigma * 2.0)));
    
    float lumaSum = 0.0;
    float2 chromaSum = float2(0.0);
    float totalWeight = 0.0;
    
    for (int y = -radius; y <= radius; y++) {
        for (int x = -radius; x <= radius; x++) {
            float distSq = float(x*x + y*y);
            float weight = exp(-distSq / twoSigmaSq);
            
            float2 sampleCoord = textureCoord + float2(x * texelSize.x, y * texelSize.y);
            
            lumaSum += lumaTexture.sample(textureSampler, sampleCoord).r * weight;
            chromaSum += chromaTexture.sample(textureSampler, sampleCoord).rg * weight;
            totalWeight += weight;
        }
    }
    
    float blurredLuma = lumaSum / totalWeight;
    float2 blurredChroma = chromaSum / totalWeight;
    
    float blendFactor = 1.0 - maskValue;
    
    float finalLuma = mix(originalLuma, blurredLuma, blendFactor);
    float2 finalChroma = mix(originalChroma, blurredChroma, blendFactor);
    
    outputLumaTexture.write(float4(finalLuma, 0.0, 0.0, 0.0), gid);
    
    uint2 chromaCoord = uint2(gid.x / 2, gid.y / 2);
    if (chromaCoord.x < outputChromaTexture.get_width() && 
        chromaCoord.y < outputChromaTexture.get_height()) {
        outputChromaTexture.write(float4(finalChroma.x, finalChroma.y, 0.0, 0.0), chromaCoord);
    }
}
