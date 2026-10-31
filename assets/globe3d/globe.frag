// GLOBE — the planet's surface. The albedo is lit by the scene sun for
// FORM (the sphere's shading); the city lights follow the REAL Earth:
// sunGeo is the actual subsolar point right now (UTC + declination),
// expressed in the texture's own lat/lon frame, so the night mask is
// painted onto the geography and rides the rotation with it. A city in
// night stays lit across its whole visible pass; regions ignite at their
// real local dusk and go dark at their real local dawn.
//
// sunGeo comes from gl.retz() in HomeView.qml — keep the frames in sync.
// psunWorld is the PRESENTATION sun (the scene DirectionalLight) as a
// world-space direction, dotted against the world-space NORMAL — the very
// geometry the light itself shades with, so the emissive mask and the lit
// form share ONE terminator. Cities burn only where BOTH suns have set:
// the arm-beat dawn sweep extinguishes lights as it reaches them.
void MAIN()
{
    BASE_COLOR = texture(albedoTex, UV0);
    ROUGHNESS = 0.92;
    METALNESS = 0.0;
    float lat = radians(UV0.y * 180.0 - 90.0);
    float lon = radians(UV0.x * 360.0);
    vec3 s = vec3(cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat));
    float night = 1.0 - smoothstep(-0.10, 0.12, dot(s, sunGeo));
    float pnight = 1.0 - smoothstep(-0.10, 0.12, dot(normalize(NORMAL), psunWorld));
    EMISSIVE_COLOR = texture(lightsTex, UV0).rgb * (emiss * night * pnight);
}
