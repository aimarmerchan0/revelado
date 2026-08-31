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
import SwiftData
import CoreImage
import Photos

struct EditorView: View {
    let foto: Foto

    // --- Estado de la sesión de edición ---
    @State private var parametros = ParametrosEdicion.neutros
    @State private var filtroRAW: CIRAWFilter? = nil
    /// Los valores con los que el revelador abrió el RAW (el punto cero).
    @State private var basesRAW: MotorRevelado.BasesRAW? = nil
    @State private var imagenBase: CIImage? = nil
    /// Máscaras de selección (sujeto por IA, cielo y verdes por análisis),
    /// calculadas una vez por foto, en segundo plano.
    @State private var mascaras = MotorRevelado.Mascaras()
    @State private var buscandoSelecciones = false
    @State private var seleccionesListas = false

    /// Portapapeles de ajustes, compartido entre fotos durante la sesión.
    static var recetaCopiada: ParametrosEdicion? = nil

    /// Modo inteligente de presets: aplicar un look ejecuta también el Auto.
    @State private var presetsInteligentes = true
    @State private var nombreNuevoPreset = ""
    @State private var pidiendoNombrePreset = false
    @Environment(\.modelContext) private var contextoDatos
    @Query(sort: \PresetGuardado.fechaCreacion, order: .reverse)
    private var presetsGuardados: [PresetGuardado]
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
    @State private var recorteSombras = false
    @State private var recorteLuces = false

    // --- Zoom del visor ---
    @State private var escalaZoom: CGFloat = 1
    @State private var escalaZoomBase: CGFloat = 1
    @State private var desplazamientoZoom: CGSize = .zero
    @State private var desplazamientoZoomBase: CGSize = .zero

    // --- Deshacer / rehacer ---
    @State private var historial: [ParametrosEdicion] = []
    @State private var futuro: [ParametrosEdicion] = []
    @State private var aplicandoHistorial = false
    @State private var ultimoRegistroHistorial = Date.distantPast

    // --- Información EXIF ---
    @State private var mostrarInformacion = false
    @State private var metadatos: [(String, String)] = []

    /// El panel activo se recuerda entre sesiones.
    @AppStorage("panelActivoEditor") private var panelGuardado = Panel.luz.rawValue

    // --- Exportación ---
    @State private var exportando = false
    @State private var avisoExportacion: String? = nil
    @State private var tiffParaCompartir: ArchivoCompartible? = nil

    /// Los cinco paneles.
    enum Panel: String, CaseIterable, Identifiable {
        case presets = "Presets"
        case luz = "Luz"
        case color = "Color"
        case selecciones = "Selección"
        case efectos = "Efectos"
        case detalle = "Detalle"
        case recortar = "Recortar"
        var id: String { rawValue }
        var simbolo: String {
            switch self {
            case .presets: return "square.stack.3d.up"
            case .luz: return "sun.max"
            case .color: return "paintpalette"
            case .selecciones: return "sparkles"
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
                    VisorMetal(imagen: mostrandoOriginal ? (imagenOriginal ?? imagen) : imagen,
                               escala: escalaZoom,
                               desplazamiento: desplazamientoZoom)
                        .background(Color.black)
                        .contentShape(Rectangle())
                        // Doble toque: ampliar al detalle / volver a encajar.
                        .onTapGesture(count: 2) {
                            if escalaZoom > 1 {
                                escalaZoom = 1; escalaZoomBase = 1
                                desplazamientoZoom = .zero; desplazamientoZoomBase = .zero
                            } else {
                                escalaZoom = 2.5; escalaZoomBase = 2.5
                            }
                        }
                        .onTapGesture(coordinateSpace: .local) { posicion in
                            guard modoCuentagotas, escalaZoom == 1 else { return }
                            aplicarCuentagotas(en: posicion, tamanoVisor: geo.size)
                        }
                        // Pellizco para ampliar; arrastre para moverse ampliado.
                        .gesture(
                            MagnificationGesture()
                                .onChanged { valor in
                                    escalaZoom = min(8, max(1, escalaZoomBase * valor))
                                }
                                .onEnded { _ in
                                    escalaZoomBase = escalaZoom
                                    if escalaZoom == 1 {
                                        desplazamientoZoom = .zero
                                        desplazamientoZoomBase = .zero
                                    }
                                }
                        )
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { gesto in
                                    guard escalaZoom > 1 else { return }
                                    desplazamientoZoom = CGSize(
                                        width: desplazamientoZoomBase.width + gesto.translation.width,
                                        height: desplazamientoZoomBase.height + gesto.translation.height)
                                }
                                .onEnded { _ in
                                    desplazamientoZoomBase = desplazamientoZoom
                                }
                        )
                        // Antes/después manteniendo pulsado (solo sin zoom).
                        .gesture(
                            (modoCuentagotas || escalaZoom > 1) ? nil :
                            LongPressGesture(minimumDuration: 0.2)
                                .sequenced(before: DragGesture(minimumDistance: 0))
                                .onChanged { valor in
                                    if case .second = valor { mostrandoOriginal = true }
                                }
                                .onEnded { _ in mostrandoOriginal = false }
                        )
                }

                if let histograma, mostrarHistograma, !mostrandoOriginal {
                    VistaHistograma(r: histograma.r, v: histograma.v, a: histograma.a,
                                    recorteSombras: recorteSombras,
                                    recorteLuces: recorteLuces)
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
            ToolbarItemGroup(placement: .topBarLeading) {
                Button {
                    deshacer()
                } label: {
                    Label("Deshacer", systemImage: "arrow.uturn.backward")
                }
                .disabled(historial.isEmpty)

                Button {
                    rehacer()
                } label: {
                    Label("Rehacer", systemImage: "arrow.uturn.forward")
                }
                .disabled(futuro.isEmpty)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                // Antes/después fijo, además del gesto de mantener pulsado.
                Button {
                    mostrandoOriginal.toggle()
                } label: {
                    Label("Antes y después", systemImage: "square.split.2x1")
                }
                .symbolVariant(mostrandoOriginal ? .fill : .none)

                Button {
                    metadatos = (try? Biblioteca.urlOriginal(de: foto))
                        .map { MotorRevelado.compartido.leerMetadatos(de: $0) } ?? []
                    mostrarInformacion = true
                } label: {
                    Label("Información", systemImage: "info.circle")
                }

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
                    Section {
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
                        Button {
                            Task { await compartirJPEG() }
                        } label: {
                            Label("Compartir JPEG (calidad máxima)",
                                  systemImage: "square.and.arrow.up.on.square")
                        }
                    }
                    Section {
                        Button {
                            Self.recetaCopiada = parametros
                        } label: {
                            Label("Copiar ajustes", systemImage: "doc.on.doc")
                        }
                        .disabled(parametros.esNeutro)
                        Button {
                            if let receta = Self.recetaCopiada {
                                withAnimation(.snappy) { parametros = receta }
                            }
                        } label: {
                            Label("Pegar ajustes", systemImage: "doc.on.clipboard")
                        }
                        .disabled(Self.recetaCopiada == nil)
                    }
                } label: {
                    Label("Exportar", systemImage: "square.and.arrow.up")
                }
                .disabled(exportando || imagen == nil)
            }
        }
        .task { await cargar() }
        .onAppear {
            panel = Panel(rawValue: panelGuardado) ?? .luz
        }
        .onChange(of: panel) { _, nuevo in
            panelGuardado = nuevo.rawValue
        }
        .onDisappear {
            actualizarMiniatura()
        }
        .onChange(of: parametros) { anterior, _ in
            guard cargada else { return }
            registrarEnHistorial(anterior)
            recalcular()
            guardar()
        }
        .sheet(isPresented: $mostrarInformacion) {
            NavigationStack {
                List {
                    if metadatos.isEmpty {
                        Text("Este archivo no trae metadatos legibles.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(metadatos, id: \.0) { fila in
                        LabeledContent(fila.0, value: fila.1)
                    }
                }
                .navigationTitle("Información")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Cerrar") { mostrarInformacion = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .alert("Exportación", isPresented: hayAviso) {
            Button("De acuerdo", role: .cancel) { avisoExportacion = nil }
        } message: {
            Text(avisoExportacion ?? "")
        }
        .alert("Guardar preset", isPresented: $pidiendoNombrePreset) {
            TextField("Nombre del preset", text: $nombreNuevoPreset)
            Button("Guardar") { guardarPresetNuevo() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("La edición actual (tono, color, curva, mezclador y efectos) se guardará con este nombre.")
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
                    case .presets: panelPresets
                    case .luz: panelLuz
                    case .color: panelColor
                    case .selecciones: panelSelecciones
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
        FilaAjuste("Temperatura", valor: $parametros.temperatura, estilo: .temperatura)
        FilaAjuste("Matiz", valor: $parametros.matiz, estilo: .matiz)
        FilaAjuste("Intensidad", valor: $parametros.intensidad, estilo: .saturacion)
        FilaAjuste("Saturación", valor: $parametros.saturacion, estilo: .saturacion)
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

    // ---- Presets ----
    @ViewBuilder private var panelPresets: some View {
        HStack {
            Toggle(isOn: $presetsInteligentes) {
                Label("Inteligente", systemImage: "wand.and.sparkles")
                    .font(.footnote)
            }
            .toggleStyle(.button)
            .buttonStyle(.bordered)
            .tint(presetsInteligentes ? Color.accentColor : .secondary)

            Spacer()

            Button {
                nombreNuevoPreset = ""
                pidiendoNombrePreset = true
            } label: {
                Label("Guardar preset", systemImage: "plus.square.on.square")
                    .font(.footnote)
            }
            .buttonStyle(.bordered)
            .disabled(parametros.esNeutro)
        }
        .padding(.top, 8)

        Text(presetsInteligentes
             ? "Con Inteligente activado, cada look se combina con el Auto: primero se mide la foto y después se aplica el estilo."
             : "El look se aplica tal cual, sin medir la foto.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Looks.integrados) { look in
                    Button {
                        aplicarLook(look.receta)
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: look.simbolo)
                                .font(.system(size: 18))
                            Text(look.nombre)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                        .frame(width: 84, height: 56)
                        .background(Color.white.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 8)
        }

        if !presetsGuardados.isEmpty {
            Text("Mis presets")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)

            ForEach(presetsGuardados) { preset in
                HStack {
                    Button {
                        aplicarPresetGuardado(preset)
                    } label: {
                        Label(preset.nombre, systemImage: "square.stack.3d.up")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)

                    Button(role: .destructive) {
                        contextoDatos.delete(preset)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 8)
            }
        }
    }

    private func aplicarLook(_ receta: ParametrosEdicion) {
        withAnimation(.snappy) {
            parametros.fusionarLook(receta)
        }
        if presetsInteligentes {
            aplicarAuto(preservandoLook: true)
        }
    }

    /// Aplica un preset del usuario. Con Inteligente activado, adapta la
    /// exposición al tono de ESTA foto: mide su luminosidad mediana, la
    /// compara con la de la foto donde se creó el preset y compensa la
    /// diferencia en pasos EV — el mismo estilo, caiga sobre una foto clara
    /// u oscura. Después protege luces y sombras como el Auto.
    private func aplicarPresetGuardado(_ preset: PresetGuardado) {
        guard let receta = preset.parametros else { return }
        withAnimation(.snappy) {
            parametros.fusionarLook(receta)
        }
        guard presetsInteligentes else { return }

        guard let referencia = preset.tonoMedioReferencia,
              let original = imagenOriginal else {
            // Preset antiguo sin medición: al menos, Auto respetando el look.
            aplicarAuto(preservandoLook: true)
            return
        }

        Task {
            let estadisticas = await Task.detached(priority: .userInitiated) {
                MotorRevelado.compartido.estadisticasTonales(de: original)
            }.value
            guard let estadisticas else { return }
            await MainActor.run {
                withAnimation(.snappy) {
                    // Compensar la diferencia de tono entre ambas fotos.
                    let objetivo = max(0.02, referencia)
                    let actual = max(0.02, estadisticas.p50)
                    let compensacion = min(1.5, max(-1.5, log2(objetivo / actual)))
                    var exposicion = receta.exposicion + compensacion

                    // Protección de extremos, como en el Auto profesional.
                    let lucesPrevistas = min(1.5, estadisticas.p99 * pow(2, exposicion))
                    if lucesPrevistas > 0.96 {
                        let exceso = lucesPrevistas - 0.96
                        exposicion -= min(0.8, exceso * 1.5)
                        parametros.altasLuces = min(parametros.altasLuces,
                                                    -min(75, (exceso * 260).rounded()))
                    }
                    let sombrasPrevistas = estadisticas.p01 * pow(2, exposicion)
                    if sombrasPrevistas < 0.015 {
                        parametros.sombras = max(parametros.sombras,
                                                 min(60, ((0.015 - sombrasPrevistas) * 3500).rounded()))
                    }

                    parametros.exposicion = exposicion.redondeadoAPaso(0.05)
                }
            }
        }
    }

    /// Guarda el preset midiendo antes el tono medio de la foto actual,
    /// para que luego pueda adaptarse a fotos más claras u oscuras.
    private func guardarPresetNuevo() {
        let nombre = nombreNuevoPreset.trimmingCharacters(in: .whitespaces)
        guard !nombre.isEmpty else { return }
        let receta = parametros
        let original = imagenOriginal
        Task {
            let tonoMedio: Double? = await Task.detached(priority: .userInitiated) {
                guard let original else { return nil }
                return MotorRevelado.compartido.estadisticasTonales(de: original)?.p50
            }.value
            await MainActor.run {
                contextoDatos.insert(PresetGuardado(nombre: nombre,
                                                    parametros: receta,
                                                    tonoMedioReferencia: tonoMedio))
            }
        }
    }

    // ---- Selecciones (IA y análisis en el dispositivo) ----
    @ViewBuilder private var panelSelecciones: some View {
        if buscandoSelecciones {
            HStack(spacing: 8) {
                ProgressView()
                Text("Analizando la foto (sujeto, cielo, vegetación)…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
        } else if mascaras.sujeto == nil && mascaras.cielo == nil
                    && mascaras.vegetacion == nil {
            ContentUnavailableView("Sin zonas detectadas",
                                   systemImage: "person.crop.rectangle.badge.plus",
                                   description: Text("No se encontró sujeto, cielo ni vegetación en esta foto. Todo el análisis ocurre en tu iPhone."))
                .frame(height: 180)
        } else {
            Text("Zonas detectadas en tu iPhone. Cada una se ajusta por separado; el resto de la foto no se toca.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)

            if mascaras.sujeto != nil {
                seccionSeleccion("Sujeto", simbolo: "person.fill")
                FilaAjuste("Luz", valor: $parametros.realceSujeto)
                FilaAjuste("Saturación", valor: $parametros.saturacionSujeto, estilo: .saturacion)
                seccionSeleccion("Fondo", simbolo: "person.and.background.dotted")
                FilaAjuste("Luz", valor: $parametros.realceFondo)
                FilaAjuste("Saturación", valor: $parametros.saturacionFondo, estilo: .saturacion)
            }
            if mascaras.cielo != nil {
                seccionSeleccion("Cielo", simbolo: "cloud.sun.fill")
                FilaAjuste("Luz", valor: $parametros.luzCielo)
                FilaAjuste("Saturación", valor: $parametros.saturacionCielo, estilo: .saturacion)
            }
            if mascaras.vegetacion != nil {
                seccionSeleccion("Vegetación", simbolo: "leaf.fill")
                FilaAjuste("Luz", valor: $parametros.luzVerdes)
                FilaAjuste("Saturación", valor: $parametros.saturacionVerdes, estilo: .saturacion)
            }
        }
    }

    private func seccionSeleccion(_ nombre: String, simbolo: String) -> some View {
        Label(nombre, systemImage: simbolo)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
    }

    // ---- Efectos ----
    @ViewBuilder private var panelEfectos: some View {
        FilaAjuste("Textura", valor: $parametros.textura)
        FilaAjuste("Claridad", valor: $parametros.claridad)
        FilaAjuste("Quitar neblina", valor: $parametros.neblina, rango: 0...100)
        FilaAjuste("Viñeta", valor: $parametros.vineta)
        FilaAjuste("Grano", valor: $parametros.grano, rango: 0...100)
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
        let baseKelvin = foto.esRAW ? Double(basesRAW?.temperatura ?? 6500) : 6500
        let baseMatiz = foto.esRAW ? Double(basesRAW?.tinte ?? 0) : 0
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

    /// Auto profesional: mide el histograma completo del original y coloca
    /// los ajustes vigilando SIEMPRE los dos extremos — que no queden zonas
    /// negras empastadas ni luces quemadas después de la corrección.
    /// `preservandoLook` = true cuando se ejecuta como parte de un preset
    /// inteligente: entonces respeta el estilo (contraste, curva, color) y
    /// solo coloca la exposición y la protección de extremos.
    private func aplicarAuto(preservandoLook: Bool = false) {
        guard let original = imagenOriginal else { return }
        Task {
            let estadisticas = await Task.detached(priority: .userInitiated) {
                MotorRevelado.compartido.estadisticasTonales(de: original)
            }.value
            guard let estadisticas else { return }
            await MainActor.run {
                withAnimation(.snappy) {
                    // 1) Medios al gris medio fotográfico.
                    let medios = max(0.02, estadisticas.p50)
                    var exposicion = min(2.5, max(-2.5, log2(0.42 / medios)))

                    // 2) Protección de altas luces: predecir dónde quedará el
                    // 1% más luminoso tras la exposición. Si se quema, primero
                    // se recorta la subida y después se recupera con el
                    // control de altas luces.
                    let lucesPrevistas = min(1.5, estadisticas.p99 * pow(2, exposicion))
                    if lucesPrevistas > 0.96 {
                        let exceso = lucesPrevistas - 0.96
                        exposicion -= min(0.8, exceso * 1.5)
                        parametros.altasLuces = -min(75, (exceso * 260).rounded())
                    } else if !preservandoLook {
                        parametros.altasLuces = 0
                    }

                    // 3) Protección de sombras: que el 1% más oscuro no quede
                    // empastado en negro puro tras la corrección.
                    let sombrasPrevistas = estadisticas.p01 * pow(2, exposicion)
                    if sombrasPrevistas < 0.015 {
                        parametros.sombras = max(parametros.sombras,
                                                 min(60, ((0.015 - sombrasPrevistas) * 3500).rounded()))
                        parametros.negros = max(parametros.negros, 6)
                    } else if !preservandoLook {
                        // Sombras ya sanas: negros al punto justo, sin empastar.
                        parametros.negros = -min(20, (estadisticas.p05 * 220).rounded())
                        parametros.sombras = 8
                    }

                    // 4) Blancos: aprovechar el rango si las luces van cortas.
                    if !preservandoLook {
                        parametros.blancos = lucesPrevistas < 0.85
                            ? min(28, ((0.95 - lucesPrevistas) * 180).rounded())
                            : 0
                        if parametros.contraste == 0 { parametros.contraste = 12 }
                    }

                    parametros.exposicion = exposicion.redondeadoAPaso(0.05)
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
                basesRAW = MotorRevelado.compartido.leerBasesRAW(filtro)
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
            buscarSelecciones()
        } catch {
            mensajeError = error.localizedDescription
        }
    }

    private func recalcular() {
        let motor = MotorRevelado.compartido
        var base: CIImage?

        if let filtroRAW, let basesRAW {
            // Revelado completo a nivel de sensor: balance, exposición,
            // ruido y enfoque, siempre partiendo de las bases (§5.6).
            motor.configurarReveladoRAW(en: filtroRAW, bases: basesRAW,
                                        parametros: parametros)
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

        imagen = motor.aplicarAjustes(a: base, parametros: parametros,
                                      cuboHSL: cuboHSL,
                                      mascaras: mascaras,
                                      decodificadoRAW: foto.esRAW)
        actualizarHistograma()
    }

    /// Lanza la detección de zonas en segundo plano (una vez por foto):
    /// sujeto con la IA de Vision, cielo y vegetación por análisis de color.
    private func buscarSelecciones() {
        guard !seleccionesListas, !buscandoSelecciones,
              let original = imagenOriginal else { return }
        buscandoSelecciones = true
        Task {
            let resultado = await Task.detached(priority: .utility) {
                let motor = MotorRevelado.compartido
                return MotorRevelado.Mascaras(
                    sujeto: motor.mascaraSujeto(de: original),
                    cielo: motor.mascaraHeuristica(de: original, zona: .cielo),
                    vegetacion: motor.mascaraHeuristica(de: original, zona: .vegetacion))
            }.value
            await MainActor.run {
                mascaras = resultado
                buscandoSelecciones = false
                seleccionesListas = true
                // Si la receta guardada ya usaba selecciones, aplicarlas.
                if parametros.usaSelecciones {
                    recalcular()
                }
            }
        }
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
                await MainActor.run {
                    histograma = resultado
                    // Avisos de recorte: peso anormal en el primer/último
                    // escalón del histograma = negros empastados / quemados.
                    recorteSombras = max(resultado.r.first ?? 0,
                                         resultado.v.first ?? 0,
                                         resultado.a.first ?? 0) > 0.6
                    recorteLuces = max(resultado.r.last ?? 0,
                                       resultado.v.last ?? 0,
                                       resultado.a.last ?? 0) > 0.6
                }
            }
        }
    }

    private func guardar() {
        foto.parametrosJSON = parametros.esNeutro
            ? nil
            : try? JSONEncoder().encode(parametros)
    }

    // =========================================================================
    // Deshacer / rehacer: cada pausa en la edición deja una instantánea.
    // Los cambios seguidos del mismo arrastre se agrupan en una sola.
    // =========================================================================
    private func registrarEnHistorial(_ estadoAnterior: ParametrosEdicion) {
        guard !aplicandoHistorial else { return }
        futuro.removeAll()
        let ahora = Date()
        if ahora.timeIntervalSince(ultimoRegistroHistorial) > 0.8 {
            historial.append(estadoAnterior)
            if historial.count > 60 { historial.removeFirst() }
        }
        ultimoRegistroHistorial = ahora
    }

    private func deshacer() {
        guard let anterior = historial.popLast() else { return }
        futuro.append(parametros)
        aplicandoHistorial = true
        withAnimation(.snappy) { parametros = anterior }
        recalcular()
        guardar()
        aplicandoHistorial = false
    }

    private func rehacer() {
        guard let siguiente = futuro.popLast() else { return }
        historial.append(parametros)
        aplicandoHistorial = true
        withAnimation(.snappy) { parametros = siguiente }
        recalcular()
        guardar()
        aplicandoHistorial = false
    }

    /// Al salir del editor, la miniatura de la galería se regenera con la
    /// edición aplicada: la biblioteca enseña las fotos como las dejaste.
    private func actualizarMiniatura() {
        guard let imagen else { return }
        let motor = MotorRevelado.compartido
        Task.detached(priority: .utility) {
            let lado = Biblioteca.ladoMiniatura
            let extension_ = imagen.extent
            let ladoLargo = max(extension_.width, extension_.height)
            guard ladoLargo > 0 else { return }
            let factor = min(1, lado / ladoLargo)
            let pequena = imagen.transformed(by: .init(scaleX: factor, y: factor))
            guard let cg = motor.contexto.createCGImage(
                pequena, from: pequena.extent, format: .RGBA8,
                colorSpace: motor.espacioSalidaPantalla) else { return }
            let datos = UIImage(cgImage: cg).jpegData(compressionQuality: 0.85)
            await MainActor.run {
                if let datos { foto.miniatura = datos }
            }
        }
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

    @MainActor
    private func compartirJPEG() async {
        exportando = true
        defer { exportando = false }
        do {
            let url = try Biblioteca.urlOriginal(de: foto)
            let esRAW = foto.esRAW
            let receta = parametros
            let destino = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(nombreExportacion).jpg")

            try await Task.detached(priority: .userInitiated) {
                let completa = try MotorRevelado.compartido.renderizarParaExportar(
                    en: url, esRAW: esRAW, parametros: receta)
                try MotorRevelado.compartido.exportarJPEG(imagen: completa, a: destino)
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

/// Una fila de ajuste: nombre y valor arriba y, debajo, el medidor — una
/// barra a ancho completo que se rellena desde el centro (o desde la
/// izquierda si el ajuste solo crece), con pistas de color en los controles
/// que lo piden: azul→ámbar en temperatura, verde→magenta en matiz, y
/// gris→color en las saturaciones. Doble toque en cualquier parte de la
/// fila: el ajuste vuelve a cero. Vibración sutil al pasar por el cero.
struct FilaAjuste: View {
    /// La pista de color del medidor.
    enum Estilo {
        case neutro        // relleno ámbar de acento
        case temperatura   // azul (frío) → ámbar (cálido)
        case matiz         // verde → magenta
        case saturacion    // gris → color
    }

    let nombre: String
    @Binding var valor: Double
    var rango: ClosedRange<Double> = -100...100
    var paso: Double = 1
    var decimales: Int = 0
    var estilo: Estilo = .neutro

    /// Para la vibración al cruzar el cero.
    @State private var estabaEnCero = true

    init(_ nombre: String, valor: Binding<Double>,
         rango: ClosedRange<Double> = -100...100,
         paso: Double = 1, decimales: Int = 0,
         estilo: Estilo = .neutro) {
        self.nombre = nombre
        self._valor = valor
        self.rango = rango
        self.paso = paso
        self.decimales = decimales
        self.estilo = estilo
    }

    /// true si el rango arranca en 0: la barra se rellena desde la izquierda.
    private var esMonopolar: Bool { rango.lowerBound == 0 }

    private var fraccion: Double {
        (valor - rango.lowerBound) / (rango.upperBound - rango.lowerBound)
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text(nombre)
                    .font(.subheadline)
                Spacer()
                Text(valor, format: .number.precision(.fractionLength(decimales))
                    .sign(strategy: .always(includingZero: false)))
                    .font(.subheadline.weight(.medium).monospacedDigit())
                    .foregroundStyle(valor == 0 ? .secondary : Color.accentColor)
                    .contentTransition(.numericText())
            }

            GeometryReader { geo in
                let ancho = geo.size.width
                ZStack(alignment: .leading) {
                    // La pista.
                    Capsule()
                        .fill(colorPista)
                        .frame(height: 6)

                    // Marca del centro en los ajustes bipolares.
                    if !esMonopolar {
                        Rectangle()
                            .fill(Color.white.opacity(0.35))
                            .frame(width: 1.5, height: 12)
                            .position(x: ancho / 2, y: geo.size.height / 2)
                    }

                    // El relleno: desde el centro (bipolar) o la izquierda.
                    relleno(ancho: ancho, alto: geo.size.height)

                    // El mando.
                    Circle()
                        .fill(.white)
                        .frame(width: 22, height: 22)
                        .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                        .position(x: 11 + (ancho - 22) * fraccion,
                                  y: geo.size.height / 2)
                }
                .contentShape(Rectangle())
                // Doble toque en el medidor: a cero (como en los editores
                // profesionales). Toque simple: saltar a ese valor exacto.
                // El arrastre necesita moverse 2 pt para arrancar, así los
                // toques nunca quedan atrapados por él.
                .onTapGesture(count: 2) {
                    withAnimation(.snappy) { valor = 0 }
                }
                .onTapGesture(coordinateSpace: .local) { posicion in
                    let f = min(1, max(0, (posicion.x - 11) / max(1, ancho - 22)))
                    let nuevo = (rango.lowerBound
                        + f * (rango.upperBound - rango.lowerBound))
                    withAnimation(.snappy) {
                        valor = (nuevo / paso).rounded() * paso
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { gesto in
                            let f = min(1, max(0, (gesto.location.x - 11) / max(1, ancho - 22)))
                            let nuevo = (rango.lowerBound
                                + f * (rango.upperBound - rango.lowerBound))
                            valor = (nuevo / paso).rounded() * paso
                        }
                )
            }
            .frame(height: 26)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .sensoryFeedback(.selection, trigger: valor == 0) { _, ahoraEnCero in
            ahoraEnCero != estabaEnCero
        }
        .onChange(of: valor) { _, nuevo in
            estabaEnCero = (nuevo == 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(nombre): \(valor.formatted())")
        .accessibilityHint("Desliza para ajustar; doble toque para poner a cero")
        .accessibilityAdjustableAction { direccion in
            let salto = paso * 5
            switch direccion {
            case .increment: valor = min(rango.upperBound, valor + salto)
            case .decrement: valor = max(rango.lowerBound, valor - salto)
            @unknown default: break
            }
        }
    }

    /// La pista de fondo, con degradado si el control lo pide.
    private var colorPista: AnyShapeStyle {
        switch estilo {
        case .neutro:
            return AnyShapeStyle(Color.white.opacity(0.14))
        case .temperatura:
            return AnyShapeStyle(LinearGradient(
                colors: [Color(red: 0.35, green: 0.55, blue: 0.95),
                         Color(white: 0.35),
                         Color(red: 0.95, green: 0.68, blue: 0.25)],
                startPoint: .leading, endPoint: .trailing))
        case .matiz:
            return AnyShapeStyle(LinearGradient(
                colors: [Color(red: 0.35, green: 0.8, blue: 0.4),
                         Color(white: 0.35),
                         Color(red: 0.9, green: 0.35, blue: 0.75)],
                startPoint: .leading, endPoint: .trailing))
        case .saturacion:
            return AnyShapeStyle(LinearGradient(
                colors: [Color(white: 0.45),
                         Color(red: 0.95, green: 0.45, blue: 0.35)],
                startPoint: .leading, endPoint: .trailing))
        }
    }

    /// El relleno de valor (solo en la pista neutra; en las de degradado la
    /// propia pista ya cuenta la historia y basta con el mando).
    @ViewBuilder
    private func relleno(ancho: CGFloat, alto: CGFloat) -> some View {
        if estilo == .neutro && valor != 0 {
            let centro = esMonopolar ? 0 : ancho / 2
            let posicion = ancho * fraccion
            Capsule()
                .fill(Color.accentColor)
                .frame(width: max(3, abs(posicion - centro)), height: 6)
                .offset(x: min(centro, posicion))
                .allowsHitTesting(false)
        }
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
