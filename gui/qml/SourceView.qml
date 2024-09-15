import QtQuick 2.13
import QtQuick.Controls 2.13
import QtQuick.Layouts 2.13

import sphaerophoria.desphaero 1.0

Row {
    ListView {
        width: contentItem.childrenRect.width * 1.1
        height: parent.height
        model: Debugger.fileContent.split('\n').length - 1
        delegate: Row {
            required property int modelData

            property int lineNum: modelData + 1

            Breakpoint {
                size: lineNumberText.height
                line: lineNum
            }

            Cursor {
                size: lineNumberText.height
                line: lineNum
            }

            Text {
                id: lineNumberText
                text: lineNum
                font.family: "monospace"
                font.pointSize: window.font.pointSize
            }
        }
    }

    Text {
        text: Debugger.fileContent
        font.family: "monospace"
        font.pointSize: window.font.pointSize
    }
}
