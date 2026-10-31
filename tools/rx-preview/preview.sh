#!/bin/bash
# Render the Cast receiver from this repo's codec_serve.py, serve it locally,
# and shoot every face state in headless Chromium at the Bravia's canvas
# (1280x720, dpr 1.5) — party states 00-10, solo states 11-14 — with the art
# of one library title. No television, no Cast SDK (it is stubbed), ~30 s.
#   tools/rx-preview/preview.sh [library index, default 47]
# Output: ~/.cache/codec/rx-preview/pv<idx>_<state>.png
set -u
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
OUT=~/.cache/codec/rx-preview; mkdir -p "$OUT"
IDX=${1:-47}
cd "$REPO" && python3 - "$OUT" <<'PY'
import sys, re, importlib.util
sys.path.insert(0, "scripts")   # codec_serve imports its siblings (codec_paths …)
out=sys.argv[1]
spec=importlib.util.spec_from_file_location("cs","scripts/codec_serve.py"); cs=importlib.util.module_from_spec(spec); spec.loader.exec_module(cs)
h=cs._party_receiver(); h=h.decode() if isinstance(h,bytes) else h
open(out+"/rx.html","w").write(h)
open(out+"/rx.js","w").write(re.findall(r"<script>(.*?)</script>", h, re.S)[-1])
PY
node --check "$OUT/rx.js" || { echo "the served receiver does not parse"; exit 1; }
# no helper server: Chromium reads the rendered page from the file system; the
# Cast SDK and the art come through the harness's own request intercept
read -r POSTER LOGO FANART < <(curl -s http://127.0.0.1:8200/_manifest | python3 -c "import sys,json;e=json.load(sys.stdin)['entries'][$IDX];print(e.get('poster') or '-',e.get('clearlogo') or '-',e.get('fanart') or '-')")
export PV_META=$(curl -s http://127.0.0.1:8200/_manifest | python3 -c "
import sys,json;e=json.load(sys.stdin)['entries'][$IDX]
t=e.get('title','')
if e.get('kind')=='episode' and e.get('show'): t=e['show']+' \u2014 '+t
print(json.dumps({'title':t,'year':(e.get('subtitle','') or '').split(' ')[0],'rating':float(e.get('rating') or 0),'genres':e.get('genres',''),'director':e.get('director',''),'revenue':int(e.get('revenue') or 0),'budget':int(e.get('budget') or 0)}))")
[ "$POSTER" = "-" ] && POSTER=""; [ "$LOGO" = "-" ] && LOGO=""; [ "$FANART" = "-" ] && FANART=""
rm -f "$OUT"/pv${IDX}_*.png
node "$HERE/preview.mjs" "file://$OUT/rx.html" "$OUT/pv${IDX}" "$POSTER" "$LOGO" "$FANART" 2>&1 | grep -v "^shot"
ls "$OUT"/pv${IDX}_*.png | wc -l
