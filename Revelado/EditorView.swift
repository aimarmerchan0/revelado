// =============================================================================
// EditorView.swift — la mesa de revelado completa
//
// Cinco paneles, en el orden de trabajo clásico de un revelado:
//   Luz (con Auto, B/N y curva de tonos) · Color (balance de blancos con
//   cuentagotas y preajustes, intensidad, saturación y mezclador de 8 rangos)
//   · Efectos (textura, claridad, viñeta) · Detalle (enfoque, ruido)
//   · Recortar (girar, voltear, enderezar).
//
// Más el histograma en vivo y el antes/después manteniendo pulsada la foto.
// Estética nativa de Apple: materiales, estilos de texto del sistema,
// símbolos SF y controles estándar.
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

    /// La foto tal cual salió de cámara (antes/después).
    @State private var imagenOriginal: CIImage? = nil
    @State private var mostrandoOriginal = false
    /// true mientras el cuentagotas espera un toque.
    @State private var modoCuentagotas = false

    /// Cubo del mezclador HSL, regenerado solo cuando cambian sus ajustes.
    @State private var cuboHSL: Data? = nil
    @State private var hslDelCubo: [AjusteHSL] = []

    /// Rango de color seleccionado en el mezclador (0...7).
    @State private var rangoHSL = 0

    // --- Histograma ---
    @State private var histograma: (r: [Float], v: [Float], a: [Float])? = nil
    @State private var mostrarHistograma = true
    @State private var tareaHistograma: Task<Void, Never>? = nil

    // --- Exportación ---
    @State private var exportando = false
    @State private var avisoExportacion: String? = nil
    @State private var tiffParaCompartir: ArchivoCompartible? = nil

    /// Los cinco paneles.
    enum Panel: String, CaseIterable, Identifiable {
        case luz = "Luz"
        case color = "Color"
        case efectos = "Efectos"
        case detalle = "Detalle"
        case recortar = "Recortar"
        var id: String { rawValue }
        var simbolo: String {
            switch self {
            case .luz: return "sun.max"
            case .color: return "paintpalette"
            case .efectos: return "wand.and.stars"
            case .detalle: return "triangle"
            case .recortar: return "crop.rotate"
            }
        }
    }
    @State private var panel: Panel = .luz

    private let ladoLargoPrevisualizacion: CGFloat = 3000

    var body: some View {
        VStack(spacing: 0) {
            // ---- El visor ----
            ZStack(alignment: .topTrailing) {
                GeometryReader { geo in
                    VisorMetal(imagen: mostrandoOriginal ? (imagenOriginal ?? imagen) : imagen)
                        .background(Color.black)
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .local) { posicion in
                            guard modoCuentagotas else { return }
                            aplicarCuentagotas(en: posicion, tamanoVisor: geo.size)
                        }
                        .gesture(
                            modoCuentagotas ? nil :
                            LongPressGesture(minimumDuration: 0.2)
                                .sequenced(before: DragGesture(minimumDistance: 0))
                                .onChanged { valor in
                                    if case .second = valor { mostrandoOriginal = true }
                                }
                                .onEnded { _ in mostrandoOriginal = false }
                        )
                }

                if let histograma, mostrarHistograma, !mostrandoOriginal {
                    VistaHistograma(r: histograma.r, v: histograma.v, a: histograma.a)
                        .padding(10)
                        .onTapGesture { withAnimation(.snappy) { mostrarHistograma = false } }
                }

                VStack {
                    if mostrandoOriginal {
                        etiquetaVisor("Original", simbolo: nil)
                    } else if modoCuentagotas {
                        etiquetaVisor("Toca una zona que deba ser gris neutro",
                                      simbolo: "eyedropper")
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 10)

                if imagen == nil && mensajeError == nil {
                    ProgressView("Revelando…")
                        .tint(.white)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if exportando {
                    ProgressView("Exportando a resolución completa…")
                        .tint(.white)
                        .foregroundStyle(.white)
                        .padding(20)
                        .background(.ultraThinMaterial,
                                    in: RoundedRectangle(cornerRadius: 14))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    withAnimation(.snappy) { mostrarHistograma.toggle() }
                } label: {
                    Label("Histograma", systemImage: "waveform.path.ecg.rectangle")
                }
                .symbolVariant(mostrarHistograma ? .fill : .none)

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

    private func etiquetaVisor(_ texto: String, simbolo: String?) -> some View {
        HStack(spacing: 6) {
            if let simbolo { Image(systemName: simbolo) }
            Text(texto)
        }
        .font(.caption.bold())
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var hayAviso: Binding<Bool> {
        Binding(get: { avisoExportacion != nil },
                set: { siHay in if !siHay { avisoExportacion = nil } })
    }

    // =========================================================================
    // Panel de ajustes: barra de paneles + contenido
    // =========================================================================
    private var panelAjustes: some View {
        VStack(spacing: 0) {
            // La barra de paneles, desplazable, con símbolo y nombre.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Panel.allCases) { p in
                        Button {
                            withAnimation(.snappy) { panel = p }
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: p.simbolo)
                                    .font(.system(size: 17, weight: .medium))
                                Text(p.rawValue)
                                    .font(.caption2)
                            }
                            .frame(width: 66, height: 48)
                            .background(panel == p
                                        ? AnyShapeStyle(Color.accentColor.opacity(0.25))
                                        : AnyShapeStyle(.clear),
                                        in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(panel == p ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }

            ScrollView {
                VStack(spacing: 2) {
                    switch panel {
                    case .luz: panelLuz
                    case .color: panelColor
                    case .efectos: panelEfectos
                    case .detalle: panelDetalle
                    case .recortar: panelRecortar
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 12)
            }
        }
        .frame(height: 330)
        .background(.thinMaterial)
    }

    // ---- Luz ----
    @ViewBuilder private var panelLuz: some View {
        HStack {
            Button {
                aplicarAuto()
            } label: {
                Label("Auto", systemImage: "wand.and.sparkles")
            }
            .buttonStyle(.bordered)

            Button {
                withAnimation(.snappy) {
                    parametros.saturacion = parametros.saturacion == -100 ? 0 : -100
                }
            } label: {
                Label("B/N", systemImage: "circle.lefthalf.filled")
            }
            .buttonStyle(.bordered)
            .tint(parametros.saturacion == -100 ? Color.accentColor : .secondary)
            Spacer()
        }
        .padding(.top, 8)

        FilaAjuste("Exposición", valor: $parametros.exposicion,
                   rango: -5...5, paso: 0.05, decimales: 2)
        FilaAjuste("Contraste", valor: $parametros.contraste)
        FilaAjuste("Altas luces", valor: $parametros.altasLuces)
        FilaAjuste("Sombras", valor: $parametros.sombras)
        FilaAjuste("Blancos", valor: $parametros.blancos)
        FilaAjuste("Negros", valor: $parametros.negros)

        EditorCurvas(curvaLuma: $parametros.curvaLuma,
                     curvaR: $parametros.curvaR,
                     curvaV: $parametros.curvaV,
                     curvaA: $parametros.curvaA)
    }

    // ---- Color ----
    @ViewBuilder private var panelColor: some View {
        cabeceraBalanceBlancos
        FilaAjuste("Temperatura", valor: $parametros.temperatura)
        FilaAjuste("Matiz", valor: $parametros.matiz)
        FilaAjuste("Intensidad", valor: $parametros.intensidad)
        FilaAjuste("Saturación", valor: $parametros.saturacion)
        mezcladorColor
    }

    /// El mezclador: 8 pastillas de color y los tres deslizadores del rango.
    @ViewBuilder private var mezcladorColor: some View {
        Text("Mezclador de color")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)

        HStack(spacing: 10) {
            ForEach(0..<8, id: \.self) { i in
                Button {
                    withAnimation(.snappy) { rangoHSL = i }
                } label: {
                    Circle()
                        .fill(colorDelRango(i))
                        .frame(width: 26, height: 26)
                        .overlay(
                            Circle().strokeBorder(
                                rangoHSL == i ? Color.white : .clear, lineWidth: 2)
                        )
                        // Un punto marca los rangos con ajustes activos.
                        .overlay(alignment: .bottom) {
                            if !parametros.hsl[i].esNeutro {
                                Circle().fill(.white).frame(width: 4, height: 4)
                                    .offset(y: 7)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(ParametrosEdicion.nombresHSL[i])
            }
            Spacer()
        }
        .padding(.vertical, 6)

        Text(ParametrosEdicion.nombresHSL[rangoHSL])
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)

        FilaAjuste("Tono", valor: $parametros.hsl[rangoHSL].tono)
        FilaAjuste("Saturación", valor: $parametros.hsl[rangoHSL].saturacion)
        FilaAjuste("Luminancia", valor: $parametros.hsl[rangoHSL].luminancia)
    }

    private func colorDelRango(_ i: Int) -> Color {
        let (r, g, b) = ProcesadoColor.hsvARgb(ProcesadoColor.centrosTono[i], 0.85, 0.9)
        return Color(red: r, green: g, blue: b)
    }

    // ---- Efectos ----
    @ViewBuilder private var panelEfectos: some View {
        FilaAjuste("Textura", valor: $parametros.textura)
        FilaAjuste("Claridad", valor: $parametros.claridad)
        FilaAjuste("Viñeta", valor: $parametros.vineta)
    }

    // ---- Detalle ----
    @ViewBuilder private var panelDetalle: some View {
        FilaAjuste("Enfoque", valor: $parametros.enfoque, rango: 0...100)
        FilaAjuste("Reducción de ruido", valor: $parametros.reduccionRuido, rango: 0...100)
        FilaAjuste("Ruido de color", valor: $parametros.reduccionRuidoColor, rango: 0...100)
    }

    // ---- Recortar ----
    @ViewBuilder private var panelRecortar: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.snappy) { parametros.rotacion = (parametros.rotacion + 1) % 4 }
            } label: {
                Label("Girar 90°", systemImage: "rotate.right")
            }
            .buttonStyle(.bordered)

            Button {
                withAnimation(.snappy) { parametros.volteadoH.toggle() }
            } label: {
                Label("Voltear", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
            }
            .buttonStyle(.bordered)
            .tint(parametros.volteadoH ? Color.accentColor : .secondary)
            Spacer()
        }
        .padding(.top, 8)

        FilaAjuste("Enderezar", valor: $parametros.enderezar,
                   rango: -45...45, paso: 0.1, decimales: 1)
    }

    // =========================================================================
    // Balance de blancos: cuentagotas y preajustes
    // =========================================================================

    private struct PreajusteBB {
        let nombre: String
        let kelvin: Double
        let matiz: Double
    }
    private static let preajustesBB: [PreajusteBB] = [
        .init(nombre: "Luz de día", kelvin: 5500, matiz: 3),
        .init(nombre: "Nublado", kelvin: 6500, matiz: 3),
        .init(nombre: "Sombra", kelvin: 7500, matiz: 5),
        .init(nombre: "Tungsteno", kelvin: 2850, matiz: 0),
        .init(nombre: "Fluorescente", kelvin: 3800, matiz: 20),
        .init(nombre: "Flash", kelvin: 5500, matiz: 0),
    ]

    private var cabeceraBalanceBlancos: some View {
        HStack {
            Text("Balance de blancos")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                withAnimation(.snappy) { modoCuentagotas.toggle() }
            } label: {
                Image(systemName: "eyedropper")
                    .symbolVariant(modoCuentagotas ? .fill : .none)
            }
            .buttonStyle(.bordered)
            .tint(modoCuentagotas ? Color.accentColor : .secondary)
            .accessibilityLabel("Cuentagotas de punto neutro")

            Menu {
                Button("Como se disparó") { aplicarBBOriginal() }
                Divider()
                ForEach(Self.preajustesBB, id: \.nombre) { preajuste in
                    Button(preajuste.nombre) { aplicar(preajuste) }
                }
            } label: {
                Image(systemName: "list.bullet")
            }
            .buttonStyle(.bordered)
            .tint(.secondary)
            .accessibilityLabel("Preajustes de balance de blancos")
        }
        .padding(.top, 8)
    }

    private func aplicarBBOriginal() {
        withAnimation(.snappy) {
            parametros.puntoNeutroX = nil
            parametros.puntoNeutroY = nil
            parametros.neutroR = nil
            parametros.neutroG = nil
            parametros.neutroB = nil
            parametros.temperatura = 0
            parametros.matiz = 0
        }
    }

    private func aplicar(_ preajuste: PreajusteBB) {
        let baseKelvin = foto.esRAW ? Double(temperaturaBase) : 6500
        let baseMatiz = foto.esRAW ? Double(tinteBase) : 0
        withAnimation(.snappy) {
            parametros.puntoNeutroX = nil
            parametros.puntoNeutroY = nil
            parametros.neutroR = nil
            parametros.neutroG = nil
            parametros.neutroB = nil
            parametros.temperatura = ((preajuste.kelvin - baseKelvin)
                / MotorRevelado.kelvinPorUnidad).redondeadoA(-100...100)
            parametros.matiz = ((preajuste.matiz - baseMatiz)
                / MotorRevelado.matizPorUnidad).redondeadoA(-100...100)
        }
    }

    private func aplicarCuentagotas(en posicion: CGPoint, tamanoVisor: CGSize) {
        guard let extension_ = imagen?.extent,
              extension_.width > 0, extension_.height > 0,
              tamanoVisor.width > 0, tamanoVisor.height > 0 else { return }

        let escala = min(tamanoVisor.width / extension_.width,
                         tamanoVisor.height / extension_.height)
        let margenX = (tamanoVisor.width - extension_.width * escala) / 2
        let margenY = (tamanoVisor.height - extension_.height * escala) / 2

        let nx = (posicion.x - margenX) / (extension_.width * escala)
        let ny = 1 - (posicion.y - margenY) / (extension_.height * escala)
        guard (0...1).contains(nx), (0...1).contains(ny) else { return }

        withAnimation(.snappy) {
            if foto.esRAW {
                parametros.puntoNeutroX = nx
                parametros.puntoNeutroY = ny
            } else if let base = imagenBase,
                      let color = MotorRevelado.compartido.colorNeutroMuestreado(
                        en: base, puntoNormalizado: CGPoint(x: nx, y: ny)) {
                parametros.neutroR = color.0
                parametros.neutroG = color.1
                parametros.neutroB = color.2
            }
            parametros.temperatura = 0
            parametros.matiz = 0
            modoCuentagotas = false
        }
    }

    /// Auto: el fotómetro de la app. Mide la luminosidad media del original
    /// y coloca la exposición para llevarla a un gris medio, con un punto
    /// de contraste de regalo.
    private func aplicarAuto() {
        guard let original = imagenOriginal else { return }
        Task {
            let media = await Task.detached(priority: .userInitiated) {
                MotorRevelado.compartido.luminanciaMedia(de: original)
            }.value
            guard let media, media > 0 else { return }
            await MainActor.run {
                withAnimation(.snappy) {
                    // 0.45 en valores de pantalla ≈ gris medio fotográfico.
                    parametros.exposicion = min(2.5, max(-2.5, log2(0.45 / media)))
                        .redondeadoAPaso(0.05)
                    if parametros.contraste == 0 { parametros.contraste = 10 }
                }
            }
        }
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
                imagenOriginal = filtro.outputImage
                filtroRAW = filtro
            } else {
                let base = try await Task.detached(priority: .userInitiated) {
                    try MotorRevelado.compartido.cargarParaPantalla(
                        en: url, esRAW: false, ladoLargoMaximoPixeles: lado)
                }.value
                imagenBase = base
                imagenOriginal = base
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
            filtroRAW.neutralTemperature = temperaturaBase
            filtroRAW.neutralTint = tinteBase
            motor.configurarBalanceBlancosRAW(en: filtroRAW, parametros: parametros)
            base = filtroRAW.outputImage
        } else if let imagenBase {
            base = motor.aplicarBalanceBlancosNoRAW(a: imagenBase, parametros: parametros)
        }

        guard let base else { return }

        // El cubo del mezclador solo se regenera si sus ajustes cambiaron.
        if parametros.hslEsNeutro {
            cuboHSL = nil
            hslDelCubo = []
        } else if parametros.hsl != hslDelCubo {
            cuboHSL = ProcesadoColor.generarCuboHSL(parametros.hsl)
            hslDelCubo = parametros.hsl
        }

        imagen = motor.aplicarAjustes(a: base, parametros: parametros, cuboHSL: cuboHSL)
        actualizarHistograma()
    }

    /// Recalcula el histograma con un pequeño respiro (150 ms) para no
    /// hacerlo sesenta veces por segundo mientras se arrastra un deslizador.
    private func actualizarHistograma() {
        guard mostrarHistograma, let imagen else { return }
        tareaHistograma?.cancel()
        tareaHistograma = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            let resultado = await Task.detached(priority: .utility) {
                MotorRevelado.compartido.calcularHistograma(de: imagen)
            }.value
            if !Task.isCancelled, let resultado {
                await MainActor.run { histograma = resultado }
            }
        }
    }

    private func guardar() {
        foto.parametrosJSON = parametros.esNeutro
            ? nil
            : try? JSONEncoder().encode(parametros)
    }

    // =========================================================================
    // Exportación (§5.6: mismo código que la preview, escala 1.0)
    // =========================================================================

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
// Piezas reutilizables
// =============================================================================

/// Una fila de ajuste: nombre y valor arriba, deslizador a ancho completo.
/// Doble toque en el valor: ese ajuste vuelve a cero.
struct FilaAjuste: View {
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
        .padding(.vertical, 7)
    }
}

extension Double {
    /// Limita el valor a un rango y lo redondea al entero más cercano.
    func redondeadoA(_ rango: ClosedRange<Double>) -> Double {
        Swift.min(rango.upperBound, Swift.max(rango.lowerBound, self)).rounded()
    }

    /// Redondea al múltiplo más cercano de un paso (p. ej. 0.05 EV).
    func redondeadoAPaso(_ paso: Double) -> Double {
        (self / paso).rounded() * paso
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
