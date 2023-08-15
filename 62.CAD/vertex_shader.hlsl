#pragma shader_stage(vertex)

#include "common.hlsl"
#include <nbl/builtin/hlsl/shapes/beziers.hlsl>

// TODO[Lucas]: Move these functions to builtin hlsl functions (Even the shadertoy obb and aabb ones)
float cross2D(float2 a, float2 b)
{
    return determinant(float2x2(a,b));
}

float2 BezierTangent(float2 p0, float2 p1, float2 p2, float t)
{
    return 2.0 * (1.0 - t) * (p1 - p0) + 2.0 * t * (p2 - p1);
}

float2 QuadraticBezier(float2 p0, float2 p1, float2 p2, float t)
{
    return nbl::hlsl::shapes::QuadraticBezier::construct(p0, p1, p2).evaluate(t);
}

//Compute bezier in one dimension, as the OBB X and Y are at different T's
float QuadraticBezier1D(float v0, float v1, float v2, float t)
{
    float s = 1.0 - t;

    return v0 * (s * s) +
        v1 * (s * t * 2.0) +
        v2 * (t * t);
}

// Caller should make sure the lines are not parallel, i.e. cross2D(direction1, direction2) != 0, otherwise a division-by-zero will cause NaN values
float2 LineLineIntersection(float2 p1, float2 p2, float2 v1, float2 v2)
{
    // Here we're doing part of a matrix calculation because we're interested in only the intersection point not both t values
    /*
        float det = v1.y * v2.x - v1.x * v2.y;
        float2x2 inv = float2x2(v2.y, -v2.x, v1.y, -v1.x) / det;
        float2 t = mul(inv, p1 - p2);
        return p2 + mul(v2, t.y);
    */
    float denominator = v1.y * v2.x - v1.x * v2.y;
    float numerator = dot(float2(v2.y, -v2.x), p1 - p2); 

    float t = numerator / denominator;
    float2 intersectionPoint = p1 + t * v1;

    return intersectionPoint;
}

bool estimateTransformation(float2 p01, float2 p11, float2 p21, out float2 translation, out float2x2 rotation)
{
    float2 p1 = p11 - p01;
    float2 p2 = p21 - p01;

    float2 a = p2 - 2.0 * p1;
    float2 b = 2.0 * p1;

    float2 mean = a / 3.0 + b / 2.0;

    float axy = a.x * a.y;
    float bxy = a.x * b.y + b.x * a.y;
    float cxy = b.x * b.y;

    float2 aB = a * a;
    float2 bB = a * b * 2.0;
    float2 cB = b * b;

    float xy = axy / 5.0 + bxy / 4.0 + cxy / 3.0;
    float xx = aB.x / 5.0 + bB.x / 4.0 + cB.x / 3.0;
    float yy = aB.y / 5.0 + bB.y / 4.0 + cB.y / 3.0;

    float cov_00 = xx - mean.x * mean.x;
    float cov_01 = xy - mean.x * mean.y;
    float cov_11 = yy - mean.y * mean.y;

    float eigen_a = 1.0;
    float eigen_b_neghalf = -(cov_00 + cov_11) * -0.5;
    float eigen_c = (cov_00 * cov_11 - cov_01 * cov_01);

    float discr = eigen_b_neghalf * eigen_b_neghalf - eigen_a * eigen_c;
    if (discr <= 0.0)
        return false;

    discr = sqrt(discr);

    float lambda0 = (eigen_b_neghalf - discr) / eigen_a;
    float lambda1 = (eigen_b_neghalf + discr) / eigen_a;

    float2 eigenvector0 = float2(cov_01, lambda0 - cov_00);
    float2 eigenvector1 = float2(cov_01, lambda1 - cov_00);

    rotation[0] = normalize(eigenvector0);
    rotation[1] = normalize(eigenvector1);

    translation = mean + p01;

    return true;
}

// from shadertoy: https://www.shadertoy.com/view/stfSzS
float4 BezierAABB(float2 p01, float2 p11, float2 p21)
{
    float2 p0 = p01;
    float2 p1 = p11;
    float2 p2 = p21;

    float2 mi = min(p0, p2);
    float2 ma = max(p0, p2);

    float2 a = p0 - 2.0 * p1 + p2;
    float2 b = p1 - p0;
    float2 t = -b / a; // solution for linear equation at + b = 0

    if (t.x > 0.0 && t.x < 1.0) // x-coord
    {
        float q = QuadraticBezier1D(p0.x, p1.x, p2.x, t.x);

        mi.x = min(mi.x, q);
        ma.x = max(ma.x, q);
    }

    if (t.y > 0.0 && t.y < 1.0) // y-coord
    {
        float q = QuadraticBezier1D(p0.y, p1.y, p2.y, t.y);

        mi.y = min(mi.y, q);
        ma.y = max(ma.y, q);
    }

    return float4(mi, ma);
}

// from shadertoy: https://www.shadertoy.com/view/stfSzS
// OBB generation via Principal Component Analysis
bool BezierOBB_PCA(float2 p0, float2 p1, float2 p2, out float4 Pos0, out float4 Pos1, float screenSpaceLineWidth)
{
    float2x2 rotation;
    float2 translation;

    if (estimateTransformation(p0, p1, p2, translation, rotation) == false)
        return false;

    float4 aabb = BezierAABB(mul(rotation, p0 - translation), mul(rotation, p1 - translation), mul(rotation, p2 - translation));
    aabb.xy -= screenSpaceLineWidth;
    aabb.zw += screenSpaceLineWidth;
    float2 center = translation + mul((aabb.xy + aabb.zw) / 2.0f, rotation);
    float2 Extent = ((aabb.zw - aabb.xy) / 2.0f).xy;
    Pos0 = float4(center + mul(Extent, rotation), center + mul(float2(Extent.x, -Extent.y), rotation));
    Pos1 = float4(center + mul(-Extent, rotation), center + mul(-float2(Extent.x, -Extent.y), rotation));

    return true;
}

// https://pomax.github.io/bezierinfo/#splitting
// Splits curve in 2
/*
left=[]
right=[]
function drawCurvePoint(points[], t):
  if(points.length==1):
    left.add(points[0])
    right.add(points[0])
    draw(points[0])
  else:
    newpoints=array(points.size-1)
    for(i=0; i<newpoints.length; i++):
      if(i==0):
        left.add(points[i])
      if(i==newpoints.length-1):
        right.add(points[i+1])
      newpoints[i] = (1-t) * points[i] + t * points[i+1]
    drawCurvePoint(newpoints, t)
*/
Curve splitCurveTakeLeft(Curve curve, double t) 
{
    Curve outputCurve;
    outputCurve.p[0] = curve.p[0];
    outputCurve.p[1] = (1-t) * curve.p[0] + t * curve.p[1];
    outputCurve.p[2] = (1-t) * ((1-t) * curve.p[0] + t * curve.p[1]) + t * ((1-t) * curve.p[1] + t * curve.p[2]);

    return outputCurve;
}
Curve splitCurveTakeRight(Curve curve, double t) 
{
    Curve outputCurve;
    outputCurve.p[0] = curve.p[2];
    outputCurve.p[1] = (1-t) * curve.p[1] + t * curve.p[2];
    outputCurve.p[2] = (1-t) * ((1-t) * curve.p[0] + t * curve.p[1]) + t * ((1-t) * curve.p[1] + t * curve.p[2]);

    return outputCurve;
}

Curve splitCurveRange(Curve curve, double left, double right) 
{
    return splitCurveTakeLeft(splitCurveTakeRight(curve, left), right);
}

double2 transformPointNdc(double2 point2d)
{
    double4x4 transformation = globals.viewProjection;
    return mul(transformation, double4(point2d, 1, 1)).xy;
}
float2 transformPointScreenSpace(double2 point2d) 
{
    double2 ndc = transformPointNdc(point2d);
    return (float2)((ndc + 1.0) * 0.5 * globals.resolution);
}

PSInput main(uint vertexID : SV_VertexID)
{
    const uint vertexIdx = vertexID & 0x3u;
    const uint objectID = vertexID >> 2;

    DrawObject drawObj = (DrawObject) 0; //drawObjects[objectID];
    drawObj.type_subsectionIdx = 2u;
    drawObj.styleIdx = 0;

    ObjectType objType = (ObjectType)(((uint32_t)drawObj.type_subsectionIdx) & 0x0000FFFF);
    uint32_t subsectionIdx = (((uint32_t)drawObj.type_subsectionIdx) >> 16);
    PSInput outV;

    outV.setObjType(objType);
    outV.setWriteToAlpha((vertexIdx % 2u == 0u) ? 1u : 0u);

    // We only need these for Outline type objects like lines and bezier curves
    LineStyle lineStyle = lineStyles[drawObj.styleIdx];
    const float screenSpaceLineWidth = lineStyle.screenSpaceLineWidth + float(lineStyle.worldSpaceLineWidth * globals.screenToWorldRatio);
    const float antiAliasedLineWidth = screenSpaceLineWidth + globals.antiAliasingFactor * 2.0f;

    if (objType == ObjectType::LINE)
    {
        outV.setColor(lineStyle.color);
        outV.setLineThickness(screenSpaceLineWidth / 2.0f);

        double2 points[2u];
        points[0u] = vk::RawBufferLoad<double2>(drawObj.address, 8u);
        points[1u] = vk::RawBufferLoad<double2>(drawObj.address + sizeof(double2), 8u);

        float2 transformedPoints[2u];
        for (uint i = 0u; i < 2u; ++i)
        {
            transformedPoints[i] = transformPointScreenSpace(points[i]);
        }

        const float2 lineVector = normalize(transformedPoints[1u] - transformedPoints[0u]);
        const float2 normalToLine = float2(-lineVector.y, lineVector.x);

        if (vertexIdx == 0u || vertexIdx == 1u)
        {
            // work in screen space coordinates because of fixed pixel size
            outV.position.xy = transformedPoints[0u]
                + normalToLine * (((float)vertexIdx - 0.5f) * antiAliasedLineWidth)
                - lineVector * antiAliasedLineWidth * 0.5f;
        }
        else // if (vertexIdx == 2u || vertexIdx == 3u)
        {
            // work in screen space coordinates because of fixed pixel size
            outV.position.xy = transformedPoints[1u]
                + normalToLine * (((float)vertexIdx - 2.5f) * antiAliasedLineWidth)
                + lineVector * antiAliasedLineWidth * 0.5f;
        }

        outV.setLineStart(transformedPoints[0u]);
        outV.setLineEnd(transformedPoints[1u]);

        // convert back to ndc
        outV.position.xy = (outV.position.xy / globals.resolution) * 2.0 - 1.0; // back to NDC for SV_Position
        outV.position.w = 1u;
    }
    else if (objType == ObjectType::QUAD_BEZIER)
    {
        outV.setColor(lineStyle.color);
        outV.setLineThickness(screenSpaceLineWidth / 2.0f);

        double2 points[3u];
        points[0u] = vk::RawBufferLoad<double2>(drawObj.address, 8u);
        points[1u] = vk::RawBufferLoad<double2>(drawObj.address + sizeof(double2), 8u);
        points[2u] = vk::RawBufferLoad<double2>(drawObj.address + sizeof(double2) * 2u, 8u);

        // transform these points into screen space and pass to fragment
        float2 transformedPoints[3u];
        for (uint i = 0u; i < 3u; ++i)
        {
            transformedPoints[i] = transformPointScreenSpace(points[i]);
        }

        outV.setBezierP0(transformedPoints[0u]);
        outV.setBezierP1(transformedPoints[1u]);
        outV.setBezierP2(transformedPoints[2u]);

        float2 Mid = (transformedPoints[0u] + transformedPoints[2u]) / 2.0f;
        float Radius = length(Mid - transformedPoints[0u]) / 2.0f;
        
        
        /*
            B
          xxxxx
        xxx    xxx
      xxx         xx
    xxx            xx
   xx               xx
  xx                 xx
  x                   xx
A x                    x C
        */
        float2 vectorAB = transformedPoints[1u] - transformedPoints[0u];
        float2 vectorAC = transformedPoints[2u] - transformedPoints[1u];

        //T with max curve
        float MaxCurveT = dot(-(transformedPoints[1u] - transformedPoints[0u]), transformedPoints[2u] - 2.0f * transformedPoints[1u] + transformedPoints[0u]) / pow(length(transformedPoints[2u] - 2.0f * transformedPoints[1u] + transformedPoints[0u]),2.0f);

        float area = abs(vectorAB.x * vectorAC.y - vectorAB.y * vectorAC.x) * 0.5;
        float MaxCurve;
        if (length(transformedPoints[1u] - lerp(transformedPoints[0u], transformedPoints[2u], 0.25f)) > Radius && length(transformedPoints[1u] - lerp(transformedPoints[0u], transformedPoints[2u], 0.75f)) > Radius)
            MaxCurve = pow(length(transformedPoints[1u] - Mid), 3) / (area * area);
        else 
            MaxCurve = max(area / pow(length(transformedPoints[0u] - transformedPoints[1u]), 3), area / pow(length(transformedPoints[2u] - transformedPoints[1u]), 3));

        if (MaxCurve * screenSpaceLineWidth > 16)
        {
            //OBB Fallback
            float4 Pos0;
            float4 Pos1;
            if (subsectionIdx == 0 && BezierOBB_PCA(transformedPoints[0u], transformedPoints[1u], transformedPoints[2u], Pos0, Pos1, screenSpaceLineWidth / 2.0f))
            {
                if (vertexIdx == 0u)
                    outV.position = float4(Pos0.xy, 0.0, 1.0f);
                else if (vertexIdx == 1u)
                    outV.position = float4(Pos0.zw, 0.0, 1.0f);
                else if (vertexIdx == 2u)
                    outV.position = float4(Pos1.zw, 0.0, 1.0f);
                else if (vertexIdx == 3u)
                    outV.position = float4(Pos1.xy, 0.0, 1.0f);
            }
            else
                outV.position = float4(0.0f, 0.0f, 0.0f, 1.0f);
        } 
        else 
        {
            // this optimal value is hardcoded based on tests and benchmarks of pixel shader invocation
            // this is the place where we use it's tangent in the bezier to form sides the cages
            const float optimalT = 0.145f;
            
            //Whether or not to flip the the interior cage nodes
            int flip = cross2D(transformedPoints[0u] - transformedPoints[1u], transformedPoints[2u] - transformedPoints[1u]) > 0.0f ? -1 : 1;

            // Mid means bezier t = 0.5f;
            float2 MidPos = QuadraticBezier(transformedPoints[0u], transformedPoints[1u], transformedPoints[2u], 0.5f);
            float2 MidTangent = normalize(BezierTangent(transformedPoints[0u], transformedPoints[1u], transformedPoints[2u], 0.5f));
            float2 MidNormal = float2(-MidTangent.y, MidTangent.x) * flip;
            
            //re-used data
            float2 tangent;
            float2 normal;
            //exterior cage points
            float2 p0;
            float2 p1;
            //Internal cage points
            float2 IP0;
            float2 IP1;
            
            float2 Line1V1 = MidPos - MidNormal * screenSpaceLineWidth / 2.0f + MidTangent * 1000.0f;
            float2 Line1V2 = MidPos - MidNormal * screenSpaceLineWidth / 2.0f - MidTangent * 1000.0f;
            float2 Line2V1;
            float2 Line2V2;
            float2 Line3V1;
            float2 Line3V2;
            
            // Exteriors
            {
                tangent = normalize(BezierTangent(transformedPoints[0u], transformedPoints[1u], transformedPoints[2u], optimalT));
                normal = normalize(float2(-tangent.y, tangent.x)) * flip;

                Line2V1 = QuadraticBezier(transformedPoints[0u], transformedPoints[1u], transformedPoints[2u], optimalT) + tangent * 1000.0f - normal * screenSpaceLineWidth / 2.0f;
                Line2V2 = QuadraticBezier(transformedPoints[0u], transformedPoints[1u], transformedPoints[2u], optimalT) - tangent * 1000.0f - normal * screenSpaceLineWidth / 2.0f;
                //Calculating intersection between tangent line of the center(Line1) and the tangent line of the left side of bezier
                p0 = LineLineIntersection(Line1V1, Line2V1, Line1V2 - Line1V1, Line2V2 - Line2V1);
            }
            {
                tangent = normalize(BezierTangent(transformedPoints[0u], transformedPoints[1u], transformedPoints[2u], 1.0f-optimalT));
                normal = normalize(float2(-tangent.y, tangent.x)) * flip;

                Line3V1 = QuadraticBezier(transformedPoints[0u], transformedPoints[1u], transformedPoints[2u], 1.0f-optimalT) + tangent * 1000.0f - normal * screenSpaceLineWidth / 2.0f;
                Line3V2 = QuadraticBezier(transformedPoints[0u], transformedPoints[1u], transformedPoints[2u], 1.0f-optimalT) - tangent * 1000.0f - normal * screenSpaceLineWidth / 2.0f;
                //Calculating intersection between tangent line of the center(Line1) and the tangent line of the right side of bezier
                p1 = LineLineIntersection(Line1V1, Line3V1, Line1V2 - Line1V1, Line3V2 - Line3V1);
            }
            
            // Middle Cage -> Exterior
            {
                tangent = normalize(BezierTangent(transformedPoints[0u], transformedPoints[1u], transformedPoints[2u], 0.286));
                normal = normalize(float2(-tangent.y, tangent.x)) * flip;
                IP0 = QuadraticBezier(transformedPoints[0u], transformedPoints[1u], transformedPoints[2u], 0.286) + normal * screenSpaceLineWidth / 2.0f;
            }
            {
                tangent = normalize(BezierTangent(transformedPoints[0u], transformedPoints[1u], transformedPoints[2u], 0.714f));
                normal = normalize(float2(-tangent.y, tangent.x)) * flip;
                IP1 = QuadraticBezier(transformedPoints[0u], transformedPoints[1u], transformedPoints[2u], 0.714f) + normal * screenSpaceLineWidth / 2.0f;
            }
            // Middle Cage -> Adaptive Interior
            if (MaxCurve * screenSpaceLineWidth / 2.0f > 0.5f)
            {
                float2 TanMaxCurve = (normalize(BezierTangent(transformedPoints[0u], transformedPoints[1u], transformedPoints[2u], MaxCurveT)));
                float2 MaxCurvePos = QuadraticBezier(transformedPoints[0u], transformedPoints[1u], transformedPoints[2u], MaxCurveT);
                float2 TP0 = transformedPoints[0u] - MaxCurvePos;
                float2 TP1 = transformedPoints[1u] - MaxCurvePos;
                float2 TP2 = transformedPoints[2u] - MaxCurvePos;
                float angle = atan2(TanMaxCurve.y, TanMaxCurve.x);
                float cos_angle = cos(angle);
                float sin_angle = sin(angle);
                float2x2 rotmat = float2x2(cos_angle, sin_angle, -sin_angle, cos_angle);
                TP0 = mul(rotmat, TP0);
                TP1 = mul(rotmat, TP1);
                TP2 = mul(rotmat, TP2);

                float m1 = (TP1.y - TP0.y) / (TP1.x - TP0.x);
                float m2 = (TP2.y - TP1.y) / (TP2.x - TP1.x);

                float a = (m1 - m2) / (-2.0f * TP2.x + 2.0f * TP0.x);

                float y = (a * pow(screenSpaceLineWidth / 2.0f, 2)) + (1.0f / (4.0f * a));
                IP0 = mul(float2(0, y), rotmat) + MaxCurvePos;
                IP1 = IP0;
            }

            if (subsectionIdx == 0u)
            {
                tangent = normalize(BezierTangent(transformedPoints[0u], transformedPoints[1u], transformedPoints[2u], 0.0f));
                normal = normalize(float2(-tangent.y, tangent.x)) * flip;

                float2 Line0V1 = transformedPoints[0u] - normal * 1000.0f - tangent * screenSpaceLineWidth / 2.0f;
                float2 Line0V2 = transformedPoints[0u] + normal * 1000.0f - tangent * screenSpaceLineWidth / 2.0f;

                if (vertexIdx == 0u)
                    outV.position = float4(LineLineIntersection(Line2V1, Line0V1, Line2V2 - Line2V1, Line0V2 - Line0V1), 0.0, 1.0f);
                else if (vertexIdx == 1u)
                    outV.position = float4(transformedPoints[0u] + normal * screenSpaceLineWidth / 2.0f - tangent * screenSpaceLineWidth / 2.0f, 0.0, 1.0f);
                else if (vertexIdx == 2u)
                    outV.position = float4(p0, 0.0, 1.0f);
                else if (vertexIdx == 3u)
                    outV.position = float4(IP0, 0.0, 1.0f);
            }
            else if (subsectionIdx == 1u)
            {
                if (vertexIdx == 0u)
                    outV.position = float4(p0, 0.0, 1.0f);
                else if (vertexIdx == 1u)
                    outV.position = float4(IP0, 0.0, 1.0f);
                else if (vertexIdx == 2u)
                    outV.position = float4(p1, 0.0, 1.0f);
                else if (vertexIdx == 3u)
                    outV.position = float4(IP1, 0.0, 1.0f);
            }
            else if (subsectionIdx == 2u)
            {
                tangent = normalize(BezierTangent(transformedPoints[0u], transformedPoints[1u], transformedPoints[2u], 1.0f));
                normal = normalize(float2(-tangent.y, tangent.x)) * flip;

                float2 Line0V1 = transformedPoints[2u] - normal * 1000.0f + tangent * screenSpaceLineWidth / 2.0f;
                float2 Line0V2 = transformedPoints[2u] + normal * 1000.0f + tangent * screenSpaceLineWidth / 2.0f;

                if (vertexIdx == 0u)
                    outV.position = float4(LineLineIntersection(Line3V1, Line0V1, Line3V2 - Line3V1, Line0V2 - Line0V1), 0.0, 1.0f);
                else if (vertexIdx == 1u)
                    outV.position = float4(transformedPoints[2u] + normal * screenSpaceLineWidth / 2.0f + tangent * screenSpaceLineWidth / 2.0f, 0.0, 1.0f);
                else if (vertexIdx == 2u)
                    outV.position = float4(p1, 0.0, 1.0f);
                else if (vertexIdx == 3u)
                    outV.position = float4(IP1, 0.0, 1.0f);
            }
        }

        outV.position.xy = (outV.position.xy / globals.resolution) * 2.0 - 1.0;

    }
    else if (objType == ObjectType::CURVE_BOX)
    {
        outV.setColor(lineStyle.color);
        outV.setLineThickness(screenSpaceLineWidth / 2.0f);

        CurveBox curveBox = (CurveBox) 0;
        curveBox.curveTmax1 = 1.0;
        curveBox.curveTmax2 = 1.0;
        curveBox.aabbMin = double2(-230.0, -100.0);
        curveBox.aabbMax = double2(230.0, 100.0);
        Curve minCurve = (Curve) 0;
        minCurve.p[0] = double2(-200.0, -100.0);
        minCurve.p[1] = double2(-230.0, 0.0);
        minCurve.p[2] = double2(-200.0, 100.0);
        Curve maxCurve = (Curve) 0;
        maxCurve.p[0] = double2(200.0, -100.0);
        maxCurve.p[1] = double2(230.0, 0.0);
        maxCurve.p[2] = double2(200.0, 100.0);
        //CurveBox curveBox = vk::RawBufferLoad<CurveBox>(drawObj.address, 92u);
        //Curve minCurve = vk::RawBufferLoad<Curve>(curveBox.curveAddress1, 48u);
        //Curve maxCurve = vk::RawBufferLoad<Curve>(curveBox.curveAddress2, 48u);

        // splitting the curve based on tmin and tmax
        minCurve = splitCurveRange(minCurve, curveBox.curveTmin1, curveBox.curveTmax1);
        maxCurve = splitCurveRange(maxCurve, curveBox.curveTmin2, curveBox.curveTmax2);

        // transform these points into screen space and pass to fragment
        // TODO: handle case where middle is nan
        float2 minCurveTransformed[3u];
        float2 maxCurveTransformed[3u];
        for (uint i = 0u; i < 3u; ++i)
        {
            minCurveTransformed[i] = transformPointScreenSpace(minCurve.p[i]);
            maxCurveTransformed[i] = transformPointScreenSpace(maxCurve.p[i]);
        }

        outV.setCurveMinP0(minCurveTransformed[0]);
        outV.setCurveMinP1(minCurveTransformed[1]);
        outV.setCurveMinP2(minCurveTransformed[2]);
        outV.setCurveMaxP0(maxCurveTransformed[0]);
        outV.setCurveMaxP1(maxCurveTransformed[1]);
        outV.setCurveMaxP2(maxCurveTransformed[2]);

        float2 aabbMin = (float2) transformPointNdc(curveBox.aabbMin);
        float2 aabbMax = (float2) transformPointNdc(curveBox.aabbMax);
        
        if (vertexIdx == 0u)
            outV.position = float4(aabbMin.x, aabbMin.y, 0.0, 1.0f);
        else if (vertexIdx == 1u)
            outV.position = float4(aabbMax.x, aabbMin.y, 0.0, 1.0f);
        else if (vertexIdx == 2u)
            outV.position = float4(aabbMin.x, aabbMax.y, 0.0, 1.0f);
        else if (vertexIdx == 3u)
            outV.position = float4(aabbMax.x, aabbMax.y, 0.0, 1.0f);

        /*
            TODO[Lucas]:
            Another `else if` for CurveBox Object Type,
            What you basically need to do here is transform the box min,max and set `outV.position` correctly based on that + vertexIdx
            and you need to do certain outV.setXXX() functions to set the correct (transformed) data to frag shader

            Another note: you may know that for transparency we draw objects twice
            only when `writeToAlpha` is true (even provoking vertex), sdf calculations will happen and alpha will be set
            otherwise it's just a second draw to "Resolve" and the only important thing on "Resolves" is the same `outV.position` as the previous draw (basically the same cage)
            So if you do any precomputation, etc for sdf caluclations you could skip that :D and save yourself the trouble if `writeToAlpha` is false.
        */
        // TODO: likely going to do the precomputation skip optimization later ^^
    }


    // Make the cage fullscreen for testing:
#if 0
    if (subsectionIdx == 0) {
        if (vertexIdx == 0u)
            outV.position = float4(-1, -1, 0, 1);
        else if (vertexIdx == 1u)
            outV.position = float4(-1, +1, 0, 1);
        else if (vertexIdx == 2u)
            outV.position = float4(+1, -1, 0, 1);
        else if (vertexIdx == 3u)
            outV.position = float4(+1, +1, 0, 1);
    }
#endif

    return outV;
}