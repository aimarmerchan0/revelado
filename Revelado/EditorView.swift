// =============================================================================
// EditorView.swift — la mesa de revelado, al estilo de las apps de Apple
//
// Diseño según las guías de interfaz de Apple (HIG):
//  · La foto manda: visor a sangre completa sobre negro, controles aparte
//    sobre material translúcido (guía de disposición: separar contenido de
//    controles con materiales, no con líneas).
//  · Jerarquía tipográfica con los estilos del sistema (subheadline/caption),
//    que escalan solos si el usuario agranda el texto (accesibilidad).
//  · Deslizadores a ancho completo: más recorrido = más precisión.
//  · Valores en dígitos monoespaciados, que no bailan al cambiar.
//  · Categorías con símbolos SF, como la app Fotos: Luz y Color.
//
// Exportación (§5.7): TIFF 16 bits (archivo maestro, para compartir) y HEIF
// 10 bits (a Fotos), ambos a resolución nativa con perfil P3 incrustado.
// =============================================================================

import SwiftUI
import CoreImage
import Photos

struct EditorView: View {
    let foto: Foto

    // --- Estado de la sesión de edición ---
    @State private var parametros = ParametrosEdicion.neutros
    @State private var filtroRAW: CIRAWFilter? = nil
    @State private var temperaturaBase: Float = 6500
    @State private var tinteBase: Float = 0
    @State private var imagenBase: CIImage? = nil
    @State private var imagen: CIImage? = nil
    @State private var mensajeError: String? = nil
    @State private var cargada = false

    // --- Estado de exportación ---
    @State private var exportando = false
    @State private var avisoExportacion: String? = nil
    @State private var tiffParaCompartir: ArchivoCompartible? = nil

    /// Categorías de ajustes, como los círculos de la app Fotos.
    enum Categoria: String, CaseIterable, Identifiable {
        case luz = "Luz"
        case color = "Color"
        var id: String { rawValue }
        var simbolo: String {
            switch self {
            case .luz: return "sun.max"
            case .color: return "paintpalette"
            }
        }
    }
    @State private var categoria: Categoria = .luz

    private let ladoLargoPrevisualizacion: CGFloat = 3000

    var body: some View {
        VStack(spacing: 0) {
            // ---- El visor: la foto a sangre completa ----
            ZStack {
                VisorMetal(imagen: imagen)
                    .background(Color.black)

                if imagen == nil && mensajeError == nil {
                    ProgressView("Revelando…")
                        .tint(.white)
                        .foregroundStyle(.white)
                }
                if exportando {
                    ProgressView("Exportando a resolución completa…")
                        .tint(.white)
                        .foregroundStyle(.white)
                        .padding(20)
                        .background(.ultraThinMaterial,
                                    in: RoundedRectangle(cornerRadius: 14))
                }
                if let mensajeError {
                    ContentUnavailableView("No se pudo revelar",
                                           systemImage: "exclamationmark.triangle",
                                           description: Text(mensajeError))
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            panelAjustes
        }
        .background(Color.black)
        .navigationTitle(foto.nombreOriginal)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    withAnimation(.snappy) { parametros = .neutros }
                } label: {
                    Label("Restablecer", systemImage: "arrow.counterclockwise")
                }
                .disabled(parametros.esNeutro)

                Menu {
                    Button {
                        Task { await exportarAFotos() }
                    } label: {
                        Label("Guardar en Fotos (HEIF 10 bits)",
                              systemImage: "photo.badge.arrow.down")
                    }
                    Button {
                        Task { await compartirTIFF() }
                    } label: {
                        Label("Compartir TIFF de 16 bits",
                              systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Label("Exportar", systemImage: "square.and.arrow.up")
                }
                .disabled(exportando || imagen == nil)
            }
        }
        .task { await cargar() }
        .onChange(of: parametros) { _, _ in
            guard cargada else { return }
            recalcular()
            guardar()
        }
        .alert("Exportación", isPresented: hayAviso) {
            Button("De acuerdo", role: .cancel) { avisoExportacion = nil }
        } message: {
            Text(avisoExportacion ?? "")
        }
        .sheet(item: $tiffParaCompartir) { archivo in
            HojaCompartir(url: archivo.url)
                .presentationDetents([.medium, .large])
        }
    }

    private var hayAviso: Binding<Bool> {
        Binding(get: { avisoExportacion != nil },
                set: { siHay in if !siHay { avisoExportacion = nil } })
    }

    // =========================================================================
    // Panel de ajustes
    // =========================================================================
    private var panelAjustes: some View {
        VStack(spacing: 0) {
            Picker("Categoría", selection: $categoria) {
                ForEach(Categoria.allCases) { cat in
                    Label(cat.rawValue, systemImage: cat.simbolo).tag(cat)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 10)
            .padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 2) {
                    switch categoria {
                    case .luz:
                        FilaAjuste("Exposición", valor: $parametros.exposicion,
                                   rango: -5...5, paso: 0.05, decimales: 2)
                        FilaAjuste("Contraste", valor: $parametros.contraste)
                        FilaAjuste("Altas luces", valor: $parametros.altasLuces)
                        FilaAjuste("Sombras", valor: $parametros.sombras)
                        FilaAjuste("Blancos", valor: $parametros.blancos)
                        FilaAjuste("Negros", valor: $parametros.negros)
                    case .color:
                        FilaAjuste("Temperatura", valor: $parametros.temperatura)
                        FilaAjuste("Matiz", valor: $parametros.matiz)
                        FilaAjuste("Intensidad", valor: $parametros.intensidad)
                        FilaAjuste("Saturación", valor: $parametros.saturacion)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 12)
            }
        }
        .frame(height: 300)
        .background(.thinMaterial)
    }

    // =========================================================================
    // Carga, recálculo y guardado
    // =========================================================================
    private func cargar() async {
        do {
            if let json = foto.parametrosJSON,
               let guardados = try? JSONDecoder().decode(ParametrosEdicion.self, from: json) {
                parametros = guardados
            }

            let url = try Biblioteca.urlOriginal(de: foto)
            let esRAW = foto.esRAW
            let lado = ladoLargoPrevisualizacion

            if esRAW {
                let filtro = try await Task.detached(priority: .userInitiated) {
                    try MotorRevelado.compartido.filtroRAWParaEdicion(
                        en: url, ladoLargoMaximoPixeles: lado)
                }.value
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

    private func recalcular() {
        let motor = MotorRevelado.compartido
        var base: CIImage?

        if let filtroRAW {
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

    private func guardar() {
        foto.parametrosJSON = parametros.esNeutro
            ? nil
            : try? JSONEncoder().encode(parametros)
    }

    // =========================================================================
    // Exportación (§5.6: mismo código que la preview, escala 1.0)
    // =========================================================================

    /// Nombre base para los archivos exportados: el original sin extensión.
    private var nombreExportacion: String {
        let base = (foto.nombreOriginal as NSString).deletingPathExtension
        return base.isEmpty ? "Revelado" : "\(base) revelado"
    }

    @MainActor
    private func exportarAFotos() async {
        exportando = true
        defer { exportando = false }
        do {
            let estado = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard estado == .authorized || estado == .limited else {
                avisoExportacion = "Sin permiso para guardar en Fotos. Puedes dárselo en Ajustes > Revelado."
                return
            }

            let url = try Biblioteca.urlOriginal(de: foto)
            let esRAW = foto.esRAW
            let receta = parametros
            let destino = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(nombreExportacion).heic")

            try await Task.detached(priority: .userInitiated) {
                let completa = try MotorRevelado.compartido.renderizarParaExportar(
                    en: url, esRAW: esRAW, parametros: receta)
                try MotorRevelado.compartido.exportarHEIF10(imagen: completa, a: destino)
            }.value

            try await PHPhotoLibrary.shared().performChanges {
                let peticion = PHAssetCreationRequest.forAsset()
                peticion.addResource(with: .photo, fileURL: destino, options: nil)
            }
            avisoExportacion = "Guardada en Fotos a resolución completa (HEIF 10 bits, Display P3)."
        } catch {
            avisoExportacion = "No se pudo exportar: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func compartirTIFF() async {
        exportando = true
        defer { exportando = false }
        do {
            let url = try Biblioteca.urlOriginal(de: foto)
            let esRAW = foto.esRAW
            let receta = parametros
            let destino = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(nombreExportacion).tiff")

            try await Task.detached(priority: .userInitiated) {
                let completa = try MotorRevelado.compartido.renderizarParaExportar(
                    en: url, esRAW: esRAW, parametros: receta)
                try MotorRevelado.compartido.exportarTIFF16(imagen: completa, a: destino)
            }.value

            tiffParaCompartir = ArchivoCompartible(url: destino)
        } catch {
            avisoExportacion = "No se pudo exportar: \(error.localizedDescription)"
        }
    }
}

// =============================================================================
// Una fila de ajuste: nombre y valor arriba, deslizador a ancho completo
// debajo (todo el ancho de pantalla de recorrido = precisión al arrastrar).
// Doble toque en el valor: ese ajuste vuelve a cero.
// =============================================================================
private struct FilaAjuste: View {
    let nombre: String
    @Binding var valor: Double
    var rango: ClosedRange<Double> = -100...100
    var paso: Double = 1
    var decimales: Int = 0

    init(_ nombre: String, valor: Binding<Double>,
         rango: ClosedRange<Double> = -100...100,
         paso: Double = 1, decimales: Int = 0) {
        self.nombre = nombre
        self._valor = valor
        self.rango = rango
        self.paso = paso
        self.decimales = decimales
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(nombre)
                    .font(.subheadline)
                Spacer()
                Text(valor, format: .number.precision(.fractionLength(decimales))
                    .sign(strategy: .always(includingZero: false)))
                    .font(.subheadline.weight(.medium).monospacedDigit())
                    .foregroundStyle(valor == 0 ? .secondary : Color.accentColor)
                    .contentTransition(.numericText())
                    .onTapGesture(count: 2) {
                        withAnimation(.snappy) { valor = 0 }
                    }
                    .accessibilityLabel("\(nombre): \(valor.formatted())")
                    .accessibilityHint("Doble toque para poner a cero")
            }
            Slider(value: $valor, in: rango, step: paso)
        }
        .padding(.vertical, 7) // filas de ≥44 pt: objetivo táctil cómodo
    }
}

/// Envoltorio para poder presentar la hoja de compartir con .sheet(item:).
private struct ArchivoCompartible: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// La hoja de compartir estándar del sistema.
private struct HojaCompartir: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controlador: UIActivityViewController,
                                context: Context) {}
}
