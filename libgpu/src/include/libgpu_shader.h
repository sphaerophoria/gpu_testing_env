#ifndef __SPHAERO_LIBGPU_COMPILER_H__
#define __SPHAERO_LIBGPU_COMPILER_H__

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

struct libgpu_shader;
struct libgpu_shader* libgpu_create_shader(void);

bool libgpu_shader_push_input_vec3(struct libgpu_shader* shader);
bool libgpu_shader_push_output_vec4(struct libgpu_shader* shader);

bool libgpu_shader_push_command_mov4(
    struct libgpu_shader* shader,
    uint32_t id,
    uint32_t x_id, uint8_t x_sub_id,
    uint32_t y_id, uint8_t y_sub_id,
    uint32_t z_id, uint8_t z_sub_id,
    uint32_t w_id, uint8_t w_sub_id
);
bool libgpu_shader_push_command_load_input_reference(struct libgpu_shader* shader, uint32_t id, uint32_t input_idx);
bool libgpu_shader_push_command_load_output_reference(struct libgpu_shader* shader, uint32_t id, uint32_t output_idx);
bool libgpu_shader_push_command_load_constant_f32(struct libgpu_shader* shader, uint32_t id, float val);
bool libgpu_shader_push_command_load_constant_vec4(struct libgpu_shader* shader, uint32_t id, float x, float y, float z, float w);
bool libgpu_shader_push_command_load(struct libgpu_shader* shader, uint32_t src, uint32_t dest);
bool libgpu_shader_push_command_store(struct libgpu_shader* shader, uint32_t src, uint32_t dest);

struct libgpu_shader_input_defs;
struct libgpu_shader_input_defs* libgpu_shader_create_input_defs(void);
void libgpu_shader_free_input_defs(struct libgpu_shader_input_defs* defs);

bool libgpu_shader_input_defs_push_vec3(struct libgpu_shader_input_defs* defs, uint32_t offs, uint32_t stride);
// FIXME: Free input defs
bool libgpu_shader_input_compile(struct libgpu_shader_input_defs* defs, void** data, size_t* len);

// FIXME: Free compiled shader
bool libgpu_compile_shader(struct libgpu_shader* shader, void** data, size_t* len);

#endif //__SPHAERO_LIBGPU_COMPILER_H__