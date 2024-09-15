import QtQuick 2.13
import QtQuick.Controls 2.13
import QtQuick.Layouts 2.13
import sphaerophoria.desphaero 1.0

ColumnLayout {
    SplitView.preferredWidth: 200
    TabBar {
        id: bar
        TabButton {
            text: "Regs"
        }
        TabButton { text: "Vars" }
    }

    StackLayout {
        currentIndex: bar.currentIndex
        Layout.fillHeight: true

        Regs {}
        Vars {}
    }
}
