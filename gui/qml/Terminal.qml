import QtQuick 2.12
import QtQuick.Controls 2.12
import QtQuick.Layouts 2.12
import sphaerophoria.desphaero 1.0

Item {
    TextMetrics {
        id: textMetrics
        font.family: "monospace"
        font.pointSize: 16
        text: "abcdefghijklmnopqrstuvwxyz"
    }

    Column {
        anchors.fill: parent
        focus: true
        Keys.onPressed: (event) => {
            console.log("key: " + event.text.charCodeAt(0))
            TerminalBackend.inputKey(event.text.charCodeAt(0))
        }

        Repeater {
            model: TerminalBackend.height
            Row {
                id: row
                required property int index
                Repeater {
                    model: TerminalBackend.width
                    Rectangle {
                        required property int index
                        height: textMetrics.boundingRect.height
                        width: textMetrics.boundingRect.width / textMetrics.text.length

                        color: "black"
                        Text {
                            property int glyph_index: row.index * TerminalBackend.width + index
                            text: TerminalBackend.glyphs[glyph_index]
                            font.family: textMetrics.font.family
                            font.pointSize: textMetrics.font.pointSize
                            color: TerminalBackend.colors[glyph_index]
                        }
                    }
                }
            }
        }
    }
}
