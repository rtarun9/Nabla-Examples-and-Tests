#pragma shader_stage(fragment)

#include "common.hlsl"
#include <nbl/builtin/hlsl/shapes/beziers.hlsl>
#include <nbl/builtin/hlsl/shapes/line.hlsl>
#include <nbl/builtin/hlsl/algorithm.hlsl>
#include <nbl/builtin/hlsl/equations/quadratic.hlsl>

#if defined(NBL_FEATURE_FRAGMENT_SHADER_PIXEL_INTERLOCK)
[[vk::ext_instruction(/* OpBeginInvocationInterlockEXT */ 5364)]]
void beginInvocationInterlockEXT();
[[vk::ext_instruction(/* OpEndInvocationInterlockEXT */ 5365)]]
void endInvocationInterlockEXT();
#endif

template<typename float_t>
struct DefaultClipper
{
    using float_t2 = vector<float_t, 2>;

    static DefaultClipper construct()
    {
        DefaultClipper ret;
        return ret;
    }

    inline float_t2 operator()(const float_t t)
    {
        const float_t ret = clamp(t, 0.0, 1.0);
        return float_t2(ret, ret);
    }
};

struct StyleAccessor
{
    uint32_t styleIdx;
    using value_type = float;

    float operator[](const uint32_t ix)
    {
        return lineStyles[styleIdx].stipplePattern[ix];
    }
};

template<typename CurveType, typename StyleAccessor>
struct StyleClipper
{
    // TODO[Przemek]: this should now also include a float phaseShift which is in style's normalized space
    static StyleClipper<CurveType, StyleAccessor> construct(StyleAccessor styleAccessor,
        CurveType curve,
        typename CurveType::ArcLengthCalculator arcLenCalc)
    {
        StyleClipper<CurveType, StyleAccessor> ret = { styleAccessor, curve, arcLenCalc };
        return ret;
    }

    float2 operator()(float t)
    {
        const LineStyle style = lineStyles[styleAccessor.styleIdx];
        const float arcLen = arcLenCalc.calcArcLen(t);
        t = clamp(t, 0.0f, 1.0f);
        const float worldSpaceArcLen = arcLen * float(globals.worldToScreenRatio);
        // TODO[Przemek]: apply the phase shift of the curve here as well
        float normalizedPlaceInPattern = frac(worldSpaceArcLen * style.reciprocalStipplePatternLen + style.phaseShift);
        uint32_t patternIdx = nbl::hlsl::upper_bound(styleAccessor, 0, style.stipplePatternSize, normalizedPlaceInPattern);

        // odd patternIdx means a "no draw section" and current candidate should split into two nearest draw sections
        if (patternIdx & 0x1)
        {
            float diffToLeftDrawableSection = style.stipplePattern[patternIdx - 1];
            float diffToRightDrawableSection = (patternIdx == style.stipplePatternSize) ? 1.0f : style.stipplePattern[patternIdx];
            diffToLeftDrawableSection -= normalizedPlaceInPattern;
            diffToRightDrawableSection -= normalizedPlaceInPattern;

            const float patternLen = float(globals.screenToWorldRatio) / style.reciprocalStipplePatternLen;
            float scrSpcOffsetToArcLen0 = diffToLeftDrawableSection * patternLen;
            float scrSpcOffsetToArcLen1 = diffToRightDrawableSection * patternLen;

            const float arcLenForT0 = arcLen + scrSpcOffsetToArcLen0;
            const float arcLenForT1 = arcLen + scrSpcOffsetToArcLen1;
            const float totalArcLen = arcLenCalc.calcArcLen(1.0f);

            // TODO [Erfan]: implement, for now code below fills "no draw sections" at begginging and end of curves
            //const float t0 = (0.0f <= arcLenForT0 && totalArcLen >= arcLenForT0) ? arcLenCalc.calcArcLenInverse(curve, arcLen + scrSpcOffsetToArcLen0, 0.000001f, t) : t;
            //const float t1 = (0.0f <= arcLenForT1 && totalArcLen >= arcLenForT1) ? arcLenCalc.calcArcLenInverse(curve, arcLen + scrSpcOffsetToArcLen1, 0.000001f, t) : t;

            const float t0 = arcLenCalc.calcArcLenInverse(curve, arcLenForT0, 0.000001f, t);
            const float t1 = arcLenCalc.calcArcLenInverse(curve, arcLenForT1, 0.000001f, t);

            return float2(t0, t1);
        }
        else
        {
            return t.xx;
        }
    }

    StyleAccessor styleAccessor;
    CurveType curve;
    typename CurveType::ArcLengthCalculator arcLenCalc;
};

template<typename CurveType, typename Clipper = DefaultClipper<typename CurveType::scalar_t> >
struct ClippedSignedDistance
{
    using float_t = typename CurveType::scalar_t;
    using float_t2 = typename CurveType::float_t2;
    using float_t3 = typename CurveType::float_t3;

    const static float_t sdf(CurveType curve, float_t2 pos, float_t thickness, Clipper clipper = DefaultClipper<typename CurveType::scalar_t>::construct())
    {
        typename CurveType::Candidates candidates = curve.getClosestCandidates(pos);

        const float_t MAX_DISTANCE_SQUARED = (thickness + 1.0f) * (thickness + 1.0f);

        bool clipped = false;
        float_t closestDistanceSquared = MAX_DISTANCE_SQUARED;
        float_t closestT = 0.0f; // use numeric limits inf?
        [[unroll(CurveType::MaxCandidates)]]
        for (uint32_t i = 0; i < CurveType::MaxCandidates; i++)
        {
            const float_t candidateDistanceSquared = length(curve.evaluate(candidates[i]) - pos);
            if (candidateDistanceSquared < closestDistanceSquared)
            {
                float2 snappedTs = clipper(candidates[i]);
                if (snappedTs[0] != candidates[i])
                {
                    clipped = true;
                    // left snapped or clamped
                    const float_t leftSnappedCandidateDistanceSquared = length(curve.evaluate(snappedTs[0]) - pos);
                    if (leftSnappedCandidateDistanceSquared < closestDistanceSquared)
                    {
                        closestT = snappedTs[0];
                        closestDistanceSquared = leftSnappedCandidateDistanceSquared;
                    }

                    if (snappedTs[0] != snappedTs[1])
                    {
                        // right snapped or clamped
                        const float_t rightSnappedCandidateDistanceSquared = length(curve.evaluate(snappedTs[1]) - pos);
                        if (rightSnappedCandidateDistanceSquared < closestDistanceSquared)
                        {
                            closestT = snappedTs[1];
                            closestDistanceSquared = rightSnappedCandidateDistanceSquared;
                        }
                    }
                }
                else
                {
                    // no snapping
                    if (candidateDistanceSquared < closestDistanceSquared)
                    {
                        closestT = candidates[i];
                        closestDistanceSquared = candidateDistanceSquared;
                    }
                }
            }
        }

        float_t roundedDistance = closestDistanceSquared - thickness;


// TODO[Przemek]: if style `isRoadStyle` is true use rectCapped, else use normal roundedDistance and remove this #ifdef
#define ROUNDED
#ifdef ROUNDED
        return roundedDistance;
#else
        const float_t aaWidth = globals.antiAliasingFactor;
        float_t rectCappedDistance = roundedDistance;

        if (clipped)
        {
            float_t2 q = mul(curve.getLocalCoordinateSpace(closestT), pos - curve.evaluate(closestT));
            rectCappedDistance = capSquare(q, thickness, aaWidth);
        }
        else
            rectCappedDistance = rectCappedDistance;

        return rectCappedDistance;
#endif
    }

    static float capSquare(float_t2 q, float_t th, float_t aaWidth)
    {
        float_t2 d = abs(q) - float_t2(aaWidth, th);
        return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
    }
};

typedef StyleClipper<nbl::hlsl::shapes::Quadratic<float>, StyleAccessor> BezierStyleClipper;
typedef StyleClipper<nbl::hlsl::shapes::Line<float>, StyleAccessor> LineStyleClipper;

float4 main(PSInput input) : SV_TARGET
{
#if defined(NBL_FEATURE_FRAGMENT_SHADER_PIXEL_INTERLOCK)
    [[vk::ext_capability(/*FragmentShaderPixelInterlockEXT*/ 5378)]]
    [[vk::ext_extension("SPV_EXT_fragment_shader_interlock")]]
    vk::ext_execution_mode(/*PixelInterlockOrderedEXT*/ 5366);
#endif
	
    ObjectType objType = input.getObjType();
    float localAlpha = 0.0f;
    uint32_t currentMainObjectIdx = input.getMainObjectIdx();
    

    // TODO:[Przemek]: handle another object type POLYLINE_CONNECTOR which is our miters eventually and is and sdf of intersection of 2 or more half-planes

    if (objType == ObjectType::LINE)
    {
        const float2 start = input.getLineStart();
        const float2 end = input.getLineEnd();
        const uint32_t styleIdx = mainObjects[currentMainObjectIdx].styleIdx;
        const float thickness = input.getLineThickness();

        nbl::hlsl::shapes::Line<float> lineSegment = nbl::hlsl::shapes::Line<float>::construct(start, end);
        nbl::hlsl::shapes::Line<float>::ArcLengthCalculator arcLenCalc = nbl::hlsl::shapes::Line<float>::ArcLengthCalculator::construct(lineSegment);

        float distance;
        if (!lineStyles[styleIdx].hasStipples())
        {
            distance = ClippedSignedDistance< nbl::hlsl::shapes::Line<float> >::sdf(lineSegment, input.position.xy, thickness);
        }
        else
        {
            StyleAccessor styleAccessor = { styleIdx };
            LineStyleClipper clipper = LineStyleClipper::construct(styleAccessor, lineSegment, arcLenCalc);
            distance = ClippedSignedDistance<nbl::hlsl::shapes::Line<float>, LineStyleClipper>::sdf(lineSegment, input.position.xy, thickness, clipper);
        }

        const float antiAliasingFactor = globals.antiAliasingFactor;
        localAlpha = 1.0f - smoothstep(-antiAliasingFactor, +antiAliasingFactor, distance);
    }
    else if (objType == ObjectType::QUAD_BEZIER)
    {
        nbl::hlsl::shapes::Quadratic<float> quadratic = input.getQuadratic();
        nbl::hlsl::shapes::Quadratic<float>::ArcLengthCalculator arcLenCalc = input.getQuadraticArcLengthCalculator();
        
        const uint32_t styleIdx = mainObjects[currentMainObjectIdx].styleIdx;
        const float thickness = input.getLineThickness();
        float distance;
        
        if (!lineStyles[styleIdx].hasStipples())
        {
            distance = ClippedSignedDistance< nbl::hlsl::shapes::Quadratic<float> >::sdf(quadratic, input.position.xy, thickness);
        }
        else
        {
            StyleAccessor styleAccessor = { styleIdx };
            BezierStyleClipper clipper = BezierStyleClipper::construct(styleAccessor, quadratic, arcLenCalc);
            distance = ClippedSignedDistance<nbl::hlsl::shapes::Quadratic<float>, BezierStyleClipper>::sdf(quadratic, input.position.xy, thickness, clipper);
        }
        
        const float antiAliasingFactor = globals.antiAliasingFactor;
        localAlpha = 1.0f - smoothstep(-antiAliasingFactor, +antiAliasingFactor, distance);
    }
    else if (objType == ObjectType::CURVE_BOX) 
    {
        const float minorBBoxUv = input.getMinorBBoxUv();
        const float majorBBoxUv = input.getMajorBBoxUv();


        //outV.data7.x = (float)curveMin.A[major];
        //outV.data7.y = (float)curveMin.B[major];
        //outV.data7.z = (float)curveMax.A[major];
        //outV.data7.w = (float)curveMax.B[major];


        const float minT = clamp(input.getMinCurvePrecomputedRootFinders().computeRoots().x, 0.0, 1.0);
        const float minEv = input.getCurveMinBezier().evaluate(minT);
        
        const float maxT = clamp(input.getMaxCurvePrecomputedRootFinders().computeRoots().x, 0.0, 1.0);
        const float maxEv = input.getCurveMaxBezier().evaluate(maxT);
        
        nbl::hlsl::equations::Quadratic<float> MinCurveMinor = input.getCurveMinBezier();
        nbl::hlsl::equations::Quadratic<float> MinCurveMajor = nbl::hlsl::equations::Quadratic<float>::construct(input.data7.x, input.data7.y, 0.0 /*not important*/);
        nbl::hlsl::equations::Quadratic<float> MaxCurveMinor = input.getCurveMaxBezier();
        nbl::hlsl::equations::Quadratic<float> MaxCurveMajor = nbl::hlsl::equations::Quadratic<float>::construct(input.data7.z, input.data7.w, 0.0 /*not important*/);

        float2 tangentMinCurve = float2(
            2.0 * MinCurveMinor.a * minT + MinCurveMinor.b,
            2.0 * MinCurveMajor.a * minT + MinCurveMajor.b);
        tangentMinCurve = normalize(tangentMinCurve / float2(fwidth(minorBBoxUv), fwidth(majorBBoxUv)));

        float2 tangentMaxCurve = float2(
            2.0 * MaxCurveMinor.a * maxT + MaxCurveMinor.b,
            2.0 * MaxCurveMajor.a * maxT + MaxCurveMajor.b);
        tangentMaxCurve = normalize(tangentMaxCurve / float2(fwidth(minorBBoxUv), fwidth(majorBBoxUv)));

        float curveMinorDistance = min(
            tangentMinCurve.y * (minorBBoxUv - minEv),
            tangentMaxCurve.y * 1.0 * (maxEv - minorBBoxUv));

        const float aabbMajorDistance = min(majorBBoxUv, 1.0 - majorBBoxUv);

        const float antiAliasingFactorMinor = globals.antiAliasingFactor * fwidth(minorBBoxUv);
        const float antiAliasingFactorMajor = globals.antiAliasingFactor * fwidth(majorBBoxUv);

        localAlpha = 1.0;
        localAlpha *= smoothstep(-antiAliasingFactorMajor, 0.0, aabbMajorDistance);
        localAlpha *= smoothstep(-antiAliasingFactorMinor, antiAliasingFactorMinor, curveMinorDistance);
    }

    uint2 fragCoord = uint2(input.position.xy);
    float4 col;
    
    if (localAlpha <= 0)
        discard;

  
#if defined(NBL_FEATURE_FRAGMENT_SHADER_PIXEL_INTERLOCK)
        beginInvocationInterlockEXT();

    const uint32_t packedData = pseudoStencil[fragCoord];

    const uint32_t localQuantizedAlpha = (uint32_t)(localAlpha*255.f);
    const uint32_t quantizedAlpha = bitfieldExtract(packedData,0,AlphaBits);
    // if geomID has changed, we resolve the SDF alpha (draw using blend), else accumulate
    const uint32_t mainObjectIdx = bitfieldExtract(packedData,AlphaBits,MainObjectIdxBits);
    const bool resolve = currentMainObjectIdx!=mainObjectIdx;
    if (resolve || localQuantizedAlpha>quantizedAlpha)
        pseudoStencil[fragCoord] = bitfieldInsert(localQuantizedAlpha,currentMainObjectIdx,AlphaBits,MainObjectIdxBits);

    endInvocationInterlockEXT();
    
    if (!resolve)
        discard;
    
    // draw with previous geometry's style's color :kek:
    col = lineStyles[mainObjects[mainObjectIdx].styleIdx].color;
    col.w *= float(quantizedAlpha)/255.f;
#else
    col = input.getColor();
    col.w *= localAlpha;
#endif

    return float4(col);
}
