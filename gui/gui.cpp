#include "gui.h"
#include "app.h"
#include <QtGui/QGuiApplication>
#include <QtQml/QQmlApplicationEngine>
#include <chrono>
#include <thread>

extern "C" GuiHandle* makeGui(DebuggerHandle* debugger_handle) {
  return new GuiHandle(debugger_handle);
}

extern "C" void setDebuggerState(GuiHandle* state,
                                 DebuggerState debugger_state) {
  state->setDebuggerState(debugger_state);
}

extern "C" void setCurrentFile(struct GuiHandle* state, char const* file,
                               size_t len) {
  state->setFile(file, len);
}

extern "C" void setCurrentLine(struct GuiHandle* state, int line) {
  state->setLine(line);
}

extern "C" void setRegisters(struct GuiHandle* state,
                             const struct Register* registers,
                             size_t num_registers) {
  state->setRegisters(registers, num_registers);
}

extern "C" void setVars(struct GuiHandle* state, const struct Variable* vars,
                        size_t num_vars) {
  state->setVars(vars, num_vars);
}

extern "C" void setBreakpoints(struct GuiHandle* state,
                               const struct Breakpoint* breakpoints,
                               size_t num_breakpoints) {
  state->setBreakpoints(breakpoints, num_breakpoints);
}

extern "C" int runGui(GuiHandle* state) {
  // QGuiApplication::setAttribute(Qt::AA_EnableHighDpiScaling);

  int argc = 1;
  char* argv[] = {"desphaero"};
  QGuiApplication app(argc, argv);

  QQmlApplicationEngine engine;

  // Third, register the singleton type provider with QML by calling this
  // function in an initialization function.
  qmlRegisterSingletonInstance("sphaerophoria.desphaero", 1, 0, "Debugger",
                               state);

  engine.load(QUrl(QStringLiteral("./gui/qml/main.qml")));
  return app.exec();
}
