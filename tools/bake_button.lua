-- Bake ONE button family from its source .aseprite masters to the game PNGs.
-- Replicates import_mechui.py's button step for a SINGLE family only, so it
-- never clobbers other hand-edited assets/mechui/ art.
--   Idle.aseprite  -> btn-<n>-idle.png
--   Hover.aseprite -> btn-<n>-hover.png
--   Pressed.aseprite (3 frames) -> btn-<n>-p0.png / -p1.png / -p2.png
-- params: srcDir (…/Buttons/48x16/B<n>)  outDir (assets/mechui/buttons)  family
local srcDir = app.params["srcDir"]
local outDir = app.params["outDir"]
local family = app.params["family"]

local function flatten(spr, frame)
  local img = Image(spr.width, spr.height, spr.colorMode)
  img:drawSprite(spr, frame)
  return img
end

-- single-frame states
for _, m in ipairs({ {"Idle","idle"}, {"Hover","hover"} }) do
  local spr = app.open(srcDir.."/"..m[1]..".aseprite")
  flatten(spr, 1):saveAs(outDir.."/btn-"..family.."-"..m[2]..".png")
end
-- press animation (3 frames -> p0/p1/p2)
local pr = app.open(srcDir.."/Pressed.aseprite")
for i = 1, #pr.frames do
  flatten(pr, i):saveAs(outDir.."/btn-"..family.."-p"..(i-1)..".png")
end
print("baked family "..family.." ("..#pr.frames.." press frames)")
