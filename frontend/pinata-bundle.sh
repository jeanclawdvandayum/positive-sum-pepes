#!/usr/bin/env bash
# Build the Pinata/IPFS upload folder: the under-construction teaser site.
#
#   bash frontend/pinata-bundle.sh
#
# Produces frontend/pinata-upload/ — drag THAT FOLDER into Pinata
# ("Upload → Folder"). index.html is the under-construction page, so the
# folder root serves it on any gateway.
#
# The rolling paper is ALSO embedded into index.html (inert <template> +
# overlay viewer): IPFS gateways that only resolve the root document — like
# the wei.domains worker — still serve the whole site from one fetch.
set -euo pipefail
cd "$(dirname "$0")"

OUT=pinata-upload
rm -rf "$OUT"
mkdir -p "$OUT"

cp public/under-construction.html "$OUT/index.html"
cp public/rolling-paper.html "$OUT/rolling-paper.html"

node - "$OUT" <<'EOF'
const fs = require('fs')
const out = process.argv[2]
const index = fs.readFileSync(`${out}/index.html`, 'utf8')
const paper = fs.readFileSync(`${out}/rolling-paper.html`, 'utf8')

if (index.includes('embedded-paper')) throw new Error('already embedded')

const injection = `
<template id="embedded-paper">${paper}</template>
<div id="paper-overlay" style="display:none;position:fixed;inset:0;z-index:60;background:#f2f0e7">
  <button id="paper-close" aria-label="close the rolling paper"
    style="position:fixed;top:12px;right:16px;z-index:2;border:1px solid #20231c;background:#d5f56b;color:#20231c;font-family:ui-monospace,monospace;font-size:12px;padding:7px 12px;cursor:pointer">close ×</button>
  <iframe id="paper-frame" title="the rolling paper" style="width:100%;height:100%;border:0"></iframe>
</div>
<script>
(function () {
  var link = document.querySelector('.paper-cta a')
  var tpl = document.getElementById('embedded-paper')
  var overlay = document.getElementById('paper-overlay')
  var frame = document.getElementById('paper-frame')
  var close = document.getElementById('paper-close')
  link.addEventListener('click', function (e) {
    e.preventDefault()
    frame.srcdoc = tpl.innerHTML
    overlay.style.display = 'block'
  })
  close.addEventListener('click', function () {
    overlay.style.display = 'none'
    frame.srcdoc = ''
  })
})()
</${'script'}>
</body>`

fs.writeFileSync(`${out}/index.html`, index.replace('</body>', injection))
console.log('embedded rolling paper into index.html')
EOF

echo "wrote $OUT/:"
ls -la "$OUT"
echo
echo "drag '$(pwd)/$OUT' into Pinata as a folder upload"
