#!/bin/sh
# Compile the GS shaders to the SPIR-V that ../gpu.odin embeds.
set -e
cd "$(dirname "$0")"
for f in prim.vert prim.frag upload.comp copy.comp scanout.comp clut.comp decode.comp fsr.comp; do
	glslc -O --target-env=vulkan1.3 "$f" -o "$f.spv"
done
glslc -O --target-env=vulkan1.3 -DVRAM_DESCRIPTOR -DLANE_LOCAL_STATE prim.frag -o prim_nvidia.frag.spv
