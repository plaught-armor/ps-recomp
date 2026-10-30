#!/bin/sh
# Compile the Vulkan target's shaders to the SPIR-V that ../vk_target.odin
# embeds.
set -e
cd "$(dirname "$0")"
for f in draw.vert draw.frag frame.comp bloom.comp; do
	glslc -O --target-env=vulkan1.3 "$f" -o "$f.spv"
done
