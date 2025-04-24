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
    // Check if we're within the bounds of the output texture
    if (gid.x >= outputLumaTexture.get_width() || gid.y >= outputLumaTexture.get_height()) {
        return;
    }
    
    constexpr sampler textureSampler(filter::linear, address::clamp_to_edge);
    float2 textureCoord = float2(gid) / float2(outputLumaTexture.get_width(), outputLumaTexture.get_height());
    
    float maskValue = maskTexture.sample(textureSampler, textureCoord).r;
    
    float luma = lumaTexture.sample(textureSampler, textureCoord).r;
    float2 chroma = chromaTexture.sample(textureSampler, textureCoord).rg;

    float xPixel = (1.0 / float(outputLumaTexture.get_width())) * max(2.0, abs(blurRadius) * 2.0);
    float yPixel = (1.0 / float(outputLumaTexture.get_height())) * max(2.0, abs(blurRadius) * 2.0);
    
    // Precise Gaussian weights for a 9-tap filter
    const float weights[9] = {
        0.0162162162, // -4,-4
        0.0540540541, // -3,-3
        0.1216216216, // -2,-2
        0.1945945946, // -1,-1
        0.2270270270, // 0,0
        0.1945945946, // 1,1
        0.1216216216, // 2,2
        0.0540540541, // 3,3
        0.0162162162  // 4,4
    };

    float lumaSum = 0.0;
    float2 chromaSum = float2(0.0);
    
    const float offsets[9] = {-4.0, -3.0, -2.0, -1.0, 0.0, 1.0, 2.0, 3.0, 4.0};
    
    for (int i = 0; i < 9; i++) {
        float offset = offsets[i];
        float weight = weights[i];
        
        if (i == 4) {
            lumaSum += luma * weight;
            chromaSum += chroma * weight;
        } else {
            float2 sampleCoord = float2(textureCoord.x + offset * xPixel, 
                                         textureCoord.y + offset * yPixel);
            
            lumaSum += lumaTexture.sample(textureSampler, sampleCoord).r * weight;
            chromaSum += chromaTexture.sample(textureSampler, sampleCoord).rg * weight;
        }
    }
    
    float blendFactor = (1.0 - maskValue);
    
    float finalLuma = mix(luma, lumaSum, blendFactor);
    float2 finalChroma = mix(chroma, chromaSum, blendFactor);
    
    outputLumaTexture.write(float4(finalLuma, 0.0, 0.0, 0.0), gid);
    
    uint2 chromaCoord = uint2(gid.x / 2, gid.y / 2);
    if (chromaCoord.x < outputChromaTexture.get_width() && 
        chromaCoord.y < outputChromaTexture.get_height()) {
        outputChromaTexture.write(float4(finalChroma.x, finalChroma.y, 0.0, 0.0), chromaCoord);
    }
} 
