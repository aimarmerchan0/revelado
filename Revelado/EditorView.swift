// =============================================================================
// EditorView.swift — la mesa de revelado de una foto concreta
//
// Se llega aquí tocando una foto de la galería. Carga el original desde la
// biblioteca, lo revela en tamaño de previsualización y lo enseña en el
// visor Metal. Los controles de edición de la fase 2 (exposición, curvas,
// HSL...) vivirán en esta pantalla.
// =============================================================================

import SwiftUI
import CoreImage

struct EditorView: View {
    /// La ficha de la foto a editar.
    let foto: Foto

    @State private var imagen: CIImage? = nil
    @State private var mensajeError: String? = nil

    /// Lado largo máximo de la previsualización (§5.6): cubre de sobra la
    /// pantalla del iPhone. La exportación irá aparte, a resolución completa.
    private let ladoLargoPrevisualizacion: CGFloat = 3000

    var body: some View {
        ZStack {
            VisorMetal(imagen: imagen)
                .ignoresSafeArea(edges: .bottom)
                .background(Color.black)

            if imagen == nil && mensajeError == nil {
                ProgressView("Revelando…")
                    .tint(.white)
                    .foregroundStyle(.white)
            }

            if let mensajeError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                    Text(mensajeError)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white)
                .padding()
            }
        }
        .navigationTitle(foto.nombreOriginal)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.black, for: .navigationBar)
        // .task se ejecuta al aparecer la pantalla y se cancela solo al salir.
        .task {
            await cargar()
        }
    }

    private func cargar() async {
        do {
            let url = try Biblioteca.urlOriginal(de: foto)
            let esRAW = foto.esRAW
            let lado = ladoLargoPrevisualizacion
            // El revelado tarda un par de segundos: al laboratorio de atrás,
            // para que la interfaz no se congele.
            imagen = try await Task.detached(priority: .userInitiated) {
                try MotorRevelado.compartido.cargarParaPantalla(
                    en: url, esRAW: esRAW, ladoLargoMaximoPixeles: lado)
            }.value
        } catch {
            mensajeError = error.localizedDescription
        }
    }
}
