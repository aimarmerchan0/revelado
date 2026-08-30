// =============================================================================
// EditorView.swift — la mesa de revelado de una foto concreta
//
// Arriba, el visor Metal. Abajo, el panel de ajustes de la fase 2 (tono y
// color). Cada movimiento de un deslizador reconstruye la cadena de filtros
// desde el original y el visor la renderiza en una sola pasada (§5.4, §5.5):
// aquí no se modifica ninguna imagen, solo números.
//
// La receta se guarda automáticamente en la ficha de la foto (SwiftData):
// al volver a abrir la foto, la edición sigue ahí. El original, intacto.
// =============================================================================

import SwiftUI
import CoreImage

struct EditorView: View {
    /// La ficha de la foto a editar.
    let foto: Foto

    // --- Estado de la sesión de edición ---
    /// La receta actual (se carga de la ficha al entrar).
    @State private var parametros = ParametrosEdicion.neutros
    /// El revelador RAW vivo durante la sesión (solo fotos RAW): la
    /// temperatura y el matiz se ajustan dentro del propio revelado.
    @State private var filtroRAW: CIRAWFilter? = nil
    /// Balance de blancos con el que la cámara reveló: nuestro punto cero.
    @State private var temperaturaBase: Float = 6500
    @State private var tinteBase: Float = 0
    /// La imagen base para fotos NO RAW.
    @State private var imagenBase: CIImage? = nil
    /// El resultado actual de la cadena, listo para el visor.
    @State private var imagen: CIImage? = nil
    @State private var mensajeError: String? = nil
    @State private var cargada = false

    /// Lado largo máximo de la previsualización (§5.6).
    private let ladoLargoPrevisualizacion: CGFloat = 3000

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                VisorMetal(imagen: imagen)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            panelAjustes
        }
        .background(Color.black)
        .navigationTitle(foto.nombreOriginal)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Restablecer") {
                    parametros = .neutros
                }
                .disabled(parametros.esNeutro)
            }
        }
        .task { await cargar() }
        // Cada cambio de la receta: recalcular la cadena y guardarla.
        .onChange(of: parametros) { _, _ in
            guard cargada else { return }
            recalcular()
            guardar()
        }
    }

    // =========================================================================
    // El panel de deslizadores
    // =========================================================================
    private var panelAjustes: some View {
        ScrollView {
            VStack(spacing: 6) {
                seccion("Tono")
                fila("Exposición", $parametros.exposicion, -5...5, decimales: 2)
                fila("Contraste", $parametros.contraste, -100...100)
                fila("Altas luces", $parametros.altasLuces, -100...100)
                fila("Sombras", $parametros.sombras, -100...100)
                fila("Blancos", $parametros.blancos, -100...100)
                fila("Negros", $parametros.negros, -100...100)

                seccion("Balance de blancos")
                fila("Temperatura", $parametros.temperatura, -100...100)
                fila("Matiz", $parametros.matiz, -100...100)

                seccion("Color")
                fila("Intensidad", $parametros.intensidad, -100...100)
                fila("Saturación", $parametros.saturacion, -100...100)
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
        .frame(height: 290)
        .background(Color(.systemGray6).opacity(0.15))
    }

    private func seccion(_ titulo: String) -> some View {
        Text(titulo)
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
    }

    private func fila(_ nombre: String, _ valor: Binding<Double>,
                      _ rango: ClosedRange<Double>, decimales: Int = 0) -> some View {
        HStack(spacing: 10) {
            Text(nombre)
                .font(.caption)
                .frame(width: 86, alignment: .leading)
            Slider(value: valor, in: rango)
            Text(valor.wrappedValue, format: .number.precision(.fractionLength(decimales)))
                .font(.caption.monospacedDigit())
                .frame(width: 48, alignment: .trailing)
                .foregroundStyle(valor.wrappedValue == 0 ? .secondary : .primary)
                // Tocar el número dos veces devuelve ese ajuste a cero.
                .onTapGesture(count: 2) { valor.wrappedValue = 0 }
        }
    }

    // =========================================================================
    // Carga, recálculo y guardado
    // =========================================================================
    private func cargar() async {
        do {
            // Recuperar la receta guardada, si la hay.
            if let json = foto.parametrosJSON,
               let guardados = try? JSONDecoder().decode(ParametrosEdicion.self, from: json) {
                parametros = guardados
            }

            let url = try Biblioteca.urlOriginal(de: foto)
            let esRAW = foto.esRAW
            let lado = ladoLargoPrevisualizacion

            if esRAW {
                // Preparar el revelador (trabajo pesado, al laboratorio de atrás).
                let filtro = try await Task.detached(priority: .userInitiated) {
                    try MotorRevelado.compartido.filtroRAWParaEdicion(
                        en: url, ladoLargoMaximoPixeles: lado)
                }.value
                // El balance con el que la cámara reveló es nuestro cero.
                temperaturaBase = filtro.neutralTemperature
                tinteBase = filtro.neutralTint
                filtroRAW = filtro
            } else {
                imagenBase = try await Task.detached(priority: .userInitiated) {
                    try MotorRevelado.compartido.cargarParaPantalla(
                        en: url, esRAW: false, ladoLargoMaximoPixeles: lado)
                }.value
            }

            cargada = true
            recalcular()
        } catch {
            mensajeError = error.localizedDescription
        }
    }

    /// Reconstruye la cadena completa desde el original con la receta actual.
    /// Construirla es instantáneo (Core Image no calcula nada aún); el render
    /// real lo hace el visor en una sola pasada de GPU al dibujar (§5.4).
    private func recalcular() {
        let motor = MotorRevelado.compartido
        var base: CIImage?

        if let filtroRAW {
            // Balance de blancos DENTRO del revelado: +temperatura = cálido.
            filtroRAW.neutralTemperature = temperaturaBase + Float(parametros.temperatura) * 20
            filtroRAW.neutralTint = tinteBase + Float(parametros.matiz) * 0.3
            base = filtroRAW.outputImage
        } else if let imagenBase {
            base = motor.aplicarTemperaturaYMatiz(a: imagenBase,
                                                  temperatura: parametros.temperatura,
                                                  matiz: parametros.matiz)
        }

        guard let base else { return }
        imagen = motor.aplicarAjustes(a: base, parametros: parametros)
    }

    /// Guarda la receta en la ficha (SwiftData persiste solo).
    private func guardar() {
        foto.parametrosJSON = parametros.esNeutro
            ? nil
            : try? JSONEncoder().encode(parametros)
    }
}
