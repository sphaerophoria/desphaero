import QtQuick 2.13
import QtQuick.Controls 2.13
import QtQuick.Layouts 2.13
import sphaerophoria.desphaero 1.0

ListView {
    id: vars
    Layout.fillWidth: true
    Layout.fillHeight: true
    model: Debugger.vars

    delegate: Text {
        property var elem: Debugger.vars[index]
        text: {
            let prefix = "";
            elem.name + ": " + elem.type_name + " = " + elem.value.toString()
        }
        font.pointSize: window.font.pointSize
    }

}
