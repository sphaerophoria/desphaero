import QtQuick 2.13
import QtQuick.Controls 2.13
import QtQuick.Layouts 2.13
import sphaerophoria.desphaero 1.0

ApplicationWindow {
    id: window
    width: 800
    height: 600
    visible: true

    font.pointSize: 12

    SplitView {
        anchors.fill: parent

        ColumnLayout {
            SplitView.fillWidth: true
            SplitView.fillHeight: true

            ScrollView {
                Layout.fillHeight: true
                Layout.fillWidth: true

                SourceView {}
            }

            Button {
                text: "continue"
                onClicked: Debugger.cont()
            }
        }

        DataView {}
    }
}
