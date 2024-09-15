#include "gui.h"
#include <QtCore/QFile>
#include <QtCore/QObject>
#include <QtCore/QtGlobal>
#include <iostream>
#include <mutex>

// FIXME: This belong somewhere else probably
extern "C" void debuggerContinue(DebuggerHandle*);

struct GuiReg {
  Q_GADGET

  Q_PROPERTY(QString name MEMBER name);
  Q_PROPERTY(uint64_t value MEMBER value);

 public:
  QString name;
  uint64_t value;
};

struct GuiVar {
  Q_GADGET

  Q_PROPERTY(QString name MEMBER name);
  Q_PROPERTY(QString type_name MEMBER type_name);
  Q_PROPERTY(uint64_t value MEMBER value);

 public:
  QString name;
  QString type_name;
  uint64_t value;
};

struct GuiBreakpoint {
  Q_GADGET

  Q_PROPERTY(QString file MEMBER file);
  Q_PROPERTY(int32_t line MEMBER line);

 public:
  QString file;
  int32_t line;
};

// First, define your QObject which provides the functionality.
class GuiHandle : public QObject {
  Q_OBJECT
  Q_PROPERTY(
      QString debuggerState READ getDebuggerState NOTIFY debuggerStateChanged)
  Q_PROPERTY(int line READ getLine NOTIFY lineChanged)
  Q_PROPERTY(QString file READ getFile NOTIFY fileChanged)
  Q_PROPERTY(QString fileContent READ getFileContent NOTIFY fileChanged)
  Q_PROPERTY(QVector<GuiReg> regs READ getRegs NOTIFY regsChanged)
  Q_PROPERTY(QVector<GuiVar> vars READ getVars NOTIFY varsChanged)
  Q_PROPERTY(QVector<GuiBreakpoint> breakpoints READ getBreakpoints NOTIFY
                 breakpointsChanged)

 public:
  explicit GuiHandle(DebuggerHandle* debugger_handle, QObject* parent = nullptr)
      : QObject(parent), m_debuggerHandle(debugger_handle) {}

  QString getDebuggerState() {
    std::lock_guard<std::mutex> guard(m_mutex);
    return m_debuggerState;
  }

  void setDebuggerState(DebuggerState debugger_state) {
    {
      std::lock_guard<std::mutex> guard(m_mutex);
      switch (debugger_state) {
        case STATE_RUN:
          m_debuggerState = "running";
          break;
        case STATE_STOP:
          m_debuggerState = "stopped";
          break;
        case STATE_FINISH:
          m_debuggerState = "finished";
          break;
      }
    }
    emit debuggerStateChanged();
  }

  QString getFile() {
    std::lock_guard<std::mutex> guard(m_mutex);
    return m_file;
  }

  QString getFileContent() {
    std::lock_guard<std::mutex> guard(m_mutex);
    return m_fileContent;
  }

  void setFile(char const* file, size_t len) {
    {
      std::lock_guard<std::mutex> guard(m_mutex);
      m_file = QString(QByteArray(file, len));

      QFile f(m_file);
      if (!f.open(QFile::ReadOnly)) {
        qWarning("Not able to open %s", file);
      }
      m_fileContent = f.readAll();
    }
    emit fileChanged();
  }

  int getLine() {
    std::lock_guard<std::mutex> guard(m_mutex);
    return m_line;
  }

  void setLine(int line) {
    {
      std::lock_guard<std::mutex> guard(m_mutex);
      m_line = line;
    }
    emit lineChanged();
  }

  Q_INVOKABLE void cont() { debuggerContinue(m_debuggerHandle); }

  void setRegisters(const struct Register* registers, size_t num_registrs) {
    {
      std::lock_guard<std::mutex> guard(m_mutex);
      m_regs.clear();
      for (size_t i = 0; i < num_registrs; ++i) {
        GuiReg reg;
        reg.name = registers[i].name;
        reg.value = registers[i].value;
        m_regs.append(reg);
      }
    }
    emit regsChanged();
  }

  QVector<GuiReg> getRegs() {
    std::lock_guard<std::mutex> guard(m_mutex);
    return m_regs;
  }

  void setVars(Variable const* vars, size_t num_vars) {
    {
      std::lock_guard<std::mutex> guard(m_mutex);
      m_vars.clear();
      for (size_t i = 0; i < num_vars; ++i) {
        GuiVar var;
        var.name = vars[i].name;
        var.type_name = vars[i].type_name;
        var.value = vars[i].value;
        m_vars.append(var);
      }
    }
    emit varsChanged();
  }

  QVector<GuiVar> getVars() {
    std::lock_guard<std::mutex> guard(m_mutex);
    return m_vars;
  }

  void setBreakpoints(Breakpoint const* breakpoints, size_t num_breakpoints) {
    {
      std::lock_guard<std::mutex> guard(m_mutex);
      m_breakpoints.clear();
      for (size_t i = 0; i < num_breakpoints; ++i) {
        GuiBreakpoint bp;
        bp.file = breakpoints[i].file;
        bp.line = breakpoints[i].line;
        m_breakpoints.append(bp);
      }
    }
    emit breakpointsChanged();
  }

  QVector<GuiBreakpoint> getBreakpoints() {
    std::lock_guard<std::mutex> guard(m_mutex);
    return m_breakpoints;
  }

 signals:
  void debuggerStateChanged();
  void fileChanged();
  void lineChanged();
  void regsChanged();
  void varsChanged();
  void breakpointsChanged();

 private:
  QString m_file = QString();
  QString m_fileContent = QString();
  int m_line = 0;
  QVector<GuiReg> m_regs;
  QVector<GuiVar> m_vars;
  QVector<GuiBreakpoint> m_breakpoints;
  QString m_debuggerState = QString();
  DebuggerHandle* m_debuggerHandle;
  mutable std::mutex m_mutex;
};
