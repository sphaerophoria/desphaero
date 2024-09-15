#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct TerminalEmulatorState;
typedef void TerminalHandle;

struct TerminalEmulatorState* makeGui(TerminalHandle*);

void setState(struct TerminalEmulatorState* state, char const* content,
              size_t content_len, int width, int height);

struct Range {
  size_t start;
  size_t end;
};

struct GlyphMetadata {
  uint8_t r;
  uint8_t g;
  uint8_t b;
};

struct ScreenSnapshot {
  char const* string_buf;
  size_t string_buf_len;
  struct Range* glyphs;
  struct GlyphMetadata* metadata;
  size_t glyphs_len;
  uint32_t width;
};

void setSnapshot(struct TerminalEmulatorState* state,
                 const struct ScreenSnapshot* snapshot);

int runGui(struct TerminalEmulatorState* state);

void terminalInputKey(TerminalHandle* handle, uint8_t key);

#ifdef __cplusplus
}
#endif
