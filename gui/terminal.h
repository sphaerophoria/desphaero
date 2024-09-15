#include "terminal_gui.h"
#include <QtCore/QObject>
#include <QtGui/QColor>
#include <QtQml/QQmlApplicationEngine>
#include <iostream>
#include <mutex>

class TerminalEmulatorState : public QObject {
  Q_OBJECT
  // FIXME: Add back color
  Q_PROPERTY(QVector<QString> glyphs READ getGlyphs NOTIFY snapshotChanged)
  Q_PROPERTY(QVector<QColor> colors READ getColors NOTIFY snapshotChanged)
  Q_PROPERTY(int width READ getWidth NOTIFY snapshotChanged)
  Q_PROPERTY(int height READ getHeight NOTIFY snapshotChanged)

 public:
  explicit TerminalEmulatorState(TerminalHandle* handle,
                                 QObject* parent = nullptr)
      : QObject(parent), terminal_handle(handle) {}

  Q_INVOKABLE void inputKey(char key) {
    terminalInputKey(terminal_handle, key);
  }

  void setSnapshot(ScreenSnapshot const* snapshot) {
    {
      std::lock_guard lock(m_mutex);
      glyphs.clear();
      colors.clear();
      for (size_t i = 0; i < snapshot->glyphs_len; i++) {
        QByteArray glyph_data(
            snapshot->string_buf + snapshot->glyphs[i].start,
            snapshot->glyphs[i].end - snapshot->glyphs[i].start);

        glyphs.push_back(glyph_data);
        colors.push_back(
            QColor(qRgb(snapshot->metadata[i].r, snapshot->metadata[i].g,
                        snapshot->metadata[i].b)));
      }
      height = snapshot->string_buf_len / snapshot->width;
      width = snapshot->width;
    }

    emit snapshotChanged();
  }

  void setEngine(QQmlApplicationEngine* engine) { this->engine = engine; }

  Q_INVOKABLE void reload() {
    engine->clearComponentCache();
    engine->load(QUrl(QStringLiteral("./gui/terminal_main.qml")));
  }

  int getWidth() {
    std::lock_guard<std::mutex> lock(m_mutex);
    return width;
  }

  int getHeight() {
    std::lock_guard<std::mutex> lock(m_mutex);
    return height;
  }

  QVector<QString> getGlyphs() {
    std::lock_guard<std::mutex> lock(m_mutex);
    return glyphs;
  }

  QVector<QColor> getColors() {
    std::lock_guard<std::mutex> lock(m_mutex);
    return colors;
  }

 signals:
  void snapshotChanged();

 private:
  QVector<QString> glyphs;
  QVector<QColor> colors;
  int width = 0;
  int height = 0;
  TerminalHandle* terminal_handle = nullptr;
  QQmlApplicationEngine* engine = nullptr;
  mutable std::mutex m_mutex;
};
