// =============================================================================
// EditorCurvas.swift — la curva de tonos táctil
//
// Cuatro curvas: la general (luz) y una por canal (rojo, verde, azul).
// Interacción, la clásica de cualquier editor fotográfico:
//   · arrastrar un punto lo mueve
//   · tocar en un hueco de la curva añade un punto
//   · doble toque sobre un punto intermedio lo elimina
// La rejilla de fondo marca cuartos (sombras, medios, altas luces).
// =============================================================================

import SwiftUI

struct EditorCurvas: View {

    @Binding var curvaLuma: [PuntoCurva]
    @Binding var curvaR: [PuntoCurva]
    @Binding var curvaV: [PuntoCurva]
    @Binding var curvaA: [PuntoCurva]

    enum Canal: String, CaseIterable, Identifiable {
        case luma = "Luz"
        case rojo = "Rojo"
        case verde = "Verde"
        case azul = "Azul"
        var id: String { rawValue }
        var color: Color {
            switch self {
            case .luma: return .white
            case .rojo: return .red
            case .verde: return .green
            case .azul: return .blue
            }
        }
    }

    @State private var canal: Canal = .luma
    /// Índice del punto que se está arrastrando, si hay alguno.
    @State private var puntoActivo: Int? = nil

    private var curvaActual: Binding<[PuntoCurva]> {
        switch canal {
        case .luma: return $curvaLuma
        case .rojo: return $curvaR
        case .verde: return $curvaV
        case .azul: return $curvaA
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Curva de tonos")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Canal", selection: $canal) {
                    ForEach(Canal.allCases) { c in
                        Text(c.rawValue).tag(c)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)

                Button {
                    withAnimation(.snappy) {
                        curvaActual.wrappedValue = ParametrosEdicion.curvaIdentidad
                    }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                .disabled(curvaActual.wrappedValue == ParametrosEdicion.curvaIdentidad)
                .accessibilityLabel("Restablecer esta curva")
            }

            GeometryReader { geo in
                let ancho = geo.size.width
                let alto = geo.size.height

                ZStack {
                    // Rejilla de cuartos y diagonal de referencia.
                    Path { camino in
                        for f in [0.25, 0.5, 0.75] {
                            camino.move(to: CGPoint(x: ancho * f, y: 0))
                            camino.addLine(to: CGPoint(x: ancho * f, y: alto))
                            camino.move(to: CGPoint(x: 0, y: alto * f))
                            camino.addLine(to: CGPoint(x: ancho, y: alto * f))
                        }
                    }
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)

                    Path { camino in
                        camino.move(to: CGPoint(x: 0, y: alto))
                        camino.addLine(to: CGPoint(x: ancho, y: 0))
                    }
                    .stroke(Color.white.opacity(0.2),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                    // La curva interpolada.
                    Path { camino in
                        let muestras = ProcesadoColor.muestrearCurva(
                            curvaActual.wrappedValue, muestras: 128)
                        for (i, y) in muestras.enumerated() {
                            let px = ancho * CGFloat(i) / CGFloat(muestras.count - 1)
                            let py = alto * (1 - CGFloat(y))
                            if i == 0 { camino.move(to: CGPoint(x: px, y: py)) }
                            else { camino.addLine(to: CGPoint(x: px, y: py)) }
                        }
                    }
                    .stroke(canal.color, lineWidth: 2)

                    // Los puntos.
                    ForEach(curvaActual.wrappedValue.indices, id: \.self) { i in
                        let punto = curvaActual.wrappedValue[i]
                        Circle()
                            .fill(canal.color)
                            .frame(width: 14, height: 14)
                            .overlay(Circle().stroke(.black.opacity(0.5), lineWidth: 1))
                            .position(x: ancho * CGFloat(punto.x),
                                      y: alto * (1 - CGFloat(punto.y)))
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { valor in
                                        mover(indice: i,
                                              a: valor.location,
                                              tamano: geo.size)
                                    }
                                    .onEnded { _ in puntoActivo = nil }
                            )
                            .onTapGesture(count: 2) {
                                eliminar(indice: i)
                            }
                    }
                }
                .contentShape(Rectangle())
                // Tocar en un hueco añade un punto ahí.
                .onTapGesture(coordinateSpace: .local) { posicion in
                    anadirPunto(en: posicion, tamano: geo.size)
                }
            }
            .frame(height: 200)
            .background(Color.black.opacity(0.35),
                        in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(.top, 8)
    }

    private func mover(indice: Int, a posicion: CGPoint, tamano: CGSize) {
        var puntos = curvaActual.wrappedValue
        guard puntos.indices.contains(indice) else { return }
        puntoActivo = indice

        var nx = Double(posicion.x / tamano.width)
        let ny = Double(1 - posicion.y / tamano.height)

        // Cada punto se mueve solo entre sus vecinos (la curva no se cruza).
        let margen = 0.02
        let inferior = indice > 0 ? puntos[indice - 1].x + margen : 0
        let superior = indice < puntos.count - 1 ? puntos[indice + 1].x - margen : 1
        nx = min(max(nx, inferior), superior)

        puntos[indice] = PuntoCurva(x: min(max(nx, 0), 1),
                                    y: min(max(ny, 0), 1))
        curvaActual.wrappedValue = puntos
    }

    private func anadirPunto(en posicion: CGPoint, tamano: CGSize) {
        var puntos = curvaActual.wrappedValue
        guard puntos.count < 12 else { return }
        let nx = Double(posicion.x / tamano.width)
        let ny = Double(1 - posicion.y / tamano.height)

        // Si el toque cae encima de un punto existente, no añadir otro.
        let umbral = 0.05
        guard !puntos.contains(where: { abs($0.x - nx) < umbral }) else { return }

        puntos.append(PuntoCurva(x: min(max(nx, 0), 1),
                                 y: min(max(ny, 0), 1)))
        puntos.sort { $0.x < $1.x }
        withAnimation(.snappy) { curvaActual.wrappedValue = puntos }
    }

    private func eliminar(indice: Int) {
        var puntos = curvaActual.wrappedValue
        // Los extremos no se eliminan; los intermedios sí.
        guard puntos.count > 2,
              indice > 0, indice < puntos.count - 1 else { return }
        puntos.remove(at: indice)
        withAnimation(.snappy) { curvaActual.wrappedValue = puntos }
    }
}
