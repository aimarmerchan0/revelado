// =============================================================================
// ContentView.swift — la vista principal (por ahora, un marcador de posición)
//
// En SwiftUI la interfaz se describe declarando lo que se quiere ver, no
// dibujándolo paso a paso. Es como una hoja de contactos: describes qué fotos
// van y en qué orden, y el sistema se encarga de colocarlas.
//
// Esta pantalla es solo el "carrete de prueba" de la fase 1, punto 1: sirve
// únicamente para confirmar que el proyecto compila y arranca. En el punto 3
// la sustituiremos por el visor real basado en MTKView.
// =============================================================================

import SwiftUI

struct ContentView: View {
    var body: some View {
        // VStack apila los elementos en vertical, uno debajo de otro.
        VStack(spacing: 12) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Revelado")
                .font(.largeTitle.bold())
            Text("Proyecto en marcha. Fase 1, punto 1: cimientos.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

// Vista previa para el lienzo de Xcode (no forma parte de la app final).
#Preview {
    ContentView()
}
