// =============================================================================
// ContentView.swift — la vista principal
//
// Ahora aloja el visor Metal a pantalla completa. Mientras no haya ninguna
// foto abierta (el selector de archivos llega en el punto 4), el visor está
// en negro y encima se muestra un aviso de "sin foto".
// =============================================================================

import SwiftUI
import CoreImage

struct ContentView: View {

    /// La imagen revelada actualmente en pantalla. nil = ninguna foto abierta.
    /// @State le dice a SwiftUI: cuando esto cambie, redibuja la interfaz.
    @State private var imagenRevelada: CIImage? = nil

    var body: some View {
        ZStack {
            // El visor Metal ocupa todo, con fondo negro de sala de edición.
            VisorMetal(imagen: imagenRevelada)
                .ignoresSafeArea()
                .background(Color.black)

            // Aviso mientras no haya foto abierta.
            if imagenRevelada == nil {
                VStack(spacing: 12) {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 56))
                        .foregroundStyle(.secondary)
                    Text("Revelado")
                        .font(.largeTitle.bold())
                        .foregroundStyle(.white)
                    Text("Sin foto. El selector de archivos llega en el punto 4.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .preferredColorScheme(.dark) // sala de edición: interfaz siempre oscura
    }
}

// Vista previa para el lienzo de Xcode (no forma parte de la app final).
#Preview {
    ContentView()
}
