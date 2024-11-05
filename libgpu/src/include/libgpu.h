#ifndef __SPHAERO_LIBGPU_H__
#define __SPHAERO_LIBGPU_H__

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

struct libgpu_gpu;

struct libgpu_gpu* libgpu_gpu_create(void);
bool libgpu_gpu_create_texture(struct libgpu_gpu* gpu, uint64_t id, uint32_t width, uint32_t height);
bool libgpu_gpu_clear_color(struct libgpu_gpu* gpu, uint64_t id, float rgba[4], uint32_t minx, uint32_t maxx, uint32_t miny, uint32_t maxy);
bool libgpu_gpu_clear_depth(struct libgpu_gpu* gpu, uint64_t id, uint32_t val, uint32_t minx, uint32_t maxx, uint32_t miny, uint32_t maxy);

bool libgpu_gpu_create_dumb(struct libgpu_gpu* gpu, uint64_t id, uint64_t size);
void libgpu_free_dumb(struct libgpu_gpu* gpu, uint64_t id);

bool libgpu_gpu_get_dumb(struct libgpu_gpu* gpu, uint64_t id, void** data);

bool libgpu_gpu_get_tex_data(struct libgpu_gpu* gpu, uint64_t id, uint32_t* width, uint32_t* height, uint32_t* stride, void** data);

bool libgpu_execute_graphics_pipeline(struct libgpu_gpu* gpu, uint64_t vs, uint64_t fs, uint64_t vb, uint64_t format, uint64_t ubo, uint64_t output_tex, uint64_t depth_tex, uint64_t sampler_tex, size_t num_inputs);

#endif //__SPHAERO_LIBGPU_H__
