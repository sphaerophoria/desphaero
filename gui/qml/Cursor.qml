import QtQuick 2.13
import sphaerophoria.desphaero 1.0

Item {
    required property int size;
    required property int line;
    height: size
    width: size

    Image {
        anchors.centerIn: parent
        width: parent.width
        fillMode: Image.PreserveAspectFit
        source: {
    	    if (Debugger.line == line) {
    	        return "cursor.png"
    	    } else {
    	        return ""
    	    }
        }
    }
}
