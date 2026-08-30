// =============================================================================
// VistaHistograma.swift — el histograma en vivo
//
// Dibuja la distribución de tonos del resultado actual: tres siluetas
// superpuestas (rojo, verde, azul) sobre fondo translúcido, como el
// histograma de cualquier cámara o editor serio.
// =============================================================================

import SwiftUI

struct VistaHistograma: View {
    /// Alturas normalizadas 0...1 por canal, de sombras (izq.) a luces (der.).
    let r: [Float]
    let v: [Float]
    let a: [Float]

    var body: some View {
        ZStack {
            silueta(a, color: .blue)
            silueta(v, color: .green)
            silueta(r, color: .red)
        }
        .frame(width: 132, height: 72)
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("Histograma de la imagen")
    }

    private func silueta(_ valores: [Float], color: Color) -> some View {
        GeometryReader { geo in
            Path { camino in
                guard valores.count > 1 else { return }
                let ancho = geo.size.width
                let alto = geo.size.height
                camino.move(to: CGPoint(x: 0, y: alto))
                for (i, valor) in valores.enumerated() {
                    let px = ancho * CGFloat(i) / CGFloat(valores.count - 1)
                    let py = alto * (1 - CGFloat(min(1, valor)))
                    camino.addLine(to: CGPoint(x: px, y: py))
                }
                camino.addLine(to: CGPoint(x: geo.size.width, y: alto))
                camino.closeSubpath()
            }
            .fill(color.opacity(0.45))
        }
    }
}
