#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct GuiHandle;
typedef void DebuggerHandle;

struct GuiHandle* makeGui(DebuggerHandle*);
int runGui(struct GuiHandle*);

enum DebuggerState {
  STATE_RUN,
  STATE_STOP,
  STATE_FINISH,
};

struct Register {
  char const* name;
  uint64_t value;
};

struct Variable {
  char const* name;
  char const* type_name;
  uint64_t value;
};

struct Breakpoint {
  char const* file;
  int32_t line;
};

void setDebuggerState(struct GuiHandle* state,
                      enum DebuggerState debugger_state);
void setCurrentFile(struct GuiHandle* state, char const* file, size_t len);
void setCurrentLine(struct GuiHandle* state, int line);
void setRegisters(struct GuiHandle* state, const struct Register* registers,
                  size_t num_registrs);
void setVars(struct GuiHandle* state, const struct Variable* vars,
             size_t num_vars);
void setBreakpoints(struct GuiHandle* state,
                    const struct Breakpoint* breakpoints,
                    size_t num_breakpoints);

#ifdef __cplusplus
}
#endif
