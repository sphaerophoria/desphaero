import QtQuick 2.13
import sphaerophoria.desphaero 1.0

Item {
    required property int size;
    required property int line;
    height: size
    width: size

    Rectangle {
        anchors.centerIn: parent
        width: parent.width / 2
        height: parent.height / 2
        radius: width / 2.0
        color: {
            for (const bp of Debugger.breakpoints) {
                if (bp.file == Debugger.file && bp.line == line) {
                return "red"
                }
            }
            return "transparent"
        }
    }
}
