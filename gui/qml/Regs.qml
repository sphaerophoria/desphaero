import QtQuick 2.13
import QtQuick.Controls 2.13
import QtQuick.Layouts 2.13
import sphaerophoria.desphaero 1.0

ColumnLayout {
    id: regs

    ComboBox {
        id: format_combo
        textRole: "text"
        Layout.fillWidth: true
        model: ListModel {
            ListElement { text: "decimal"; base: 10 }
            ListElement { text: "hexidecimal"; base: 16}
        }
    }

    ListView {
        Layout.fillWidth: true
        Layout.fillHeight: true
        model: Debugger.regs

        delegate: Text {
            property var elem: Debugger.regs[index]
            text: {
                let prefix = "";
                if (format_combo.currentValue.base == 16) {
                    prefix = "0x";
                }
                elem.name + ": " + prefix + elem.value.toString(format_combo.currentValue.base)
            }
            font.pointSize: window.font.pointSize
        }

    }
}
