#include "terminal.h"
#include "terminal_gui.h"
#include <QtGui/QGuiApplication>
#include <QtQml/QQmlApplicationEngine>

extern "C" TerminalEmulatorState* makeGui(TerminalHandle* handle) {
  return new TerminalEmulatorState(handle);
}

extern "C" void setSnapshot(TerminalEmulatorState* state,
                            ScreenSnapshot const* snapshot) {
  state->setSnapshot(snapshot);
}

extern "C" int runGui(TerminalEmulatorState* state) {
  // QGuiApplication::setAttribute(Qt::AA_EnableHighDpiScaling);

  int argc = 1;
  char* argv[] = {"hello"};
  QGuiApplication app(argc, argv);

  QQmlApplicationEngine engine;
  state->setEngine(&engine);

  // Third, register the singleton type provider with QML by calling this
  // function in an initialization function.
  qmlRegisterSingletonInstance("sphaerophoria.desphaero", 1, 0, "TerminalBackend",
                               state);

  engine.load(QUrl(QStringLiteral("./gui/qml/terminal_main.qml")));
  return app.exec();
}
