// The tube glass needs LOCAL position in the fragment stage: the image
// is mapped planar onto the squashed sphere's front cap (that is how a
// real CRT image sits on a real tube), and local coords are the only
// stable frame for it while the monitor turns on the stage.
VARYING vec3 lpos;

void MAIN()
{
    lpos = VERTEX;
}
