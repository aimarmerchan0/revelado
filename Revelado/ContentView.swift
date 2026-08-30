// =============================================================================
// ContentView.swift — la vista principal
//
// El visor Metal a pantalla completa y, abajo, dos botones para abrir un RAW:
//
//   · "Carrete"  → el selector de Fotos del sistema (para los ProRAW del
//                  iPhone guardados en el carrete).
//   · "Archivos" → el explorador de archivos del sistema (para los .CR3 de
//                  la Canon copiados a iCloud Drive, al iPhone por cable, etc.)
//
// En ambos casos el archivo elegido se copia a una carpeta temporal de la app
// y se revela desde ahí. El original NUNCA se toca (§5.5).
// =============================================================================

import SwiftUI
import PhotosUI
import CoreImage
import UniformTypeIdentifiers

struct ContentView: View {

    // ---- El estado de la pantalla ----
    // @State le dice a SwiftUI: cuando esto cambie, redibuja la interfaz.

    /// La imagen revelada actualmente en pantalla. nil = ninguna foto abierta.
    @State private var imagenRevelada: CIImage? = nil
    /// La foto elegida en el carrete (aún sin revelar).
    @State private var seleccionCarrete: PhotosPickerItem? = nil
    /// Controlan si los dos selectores están abiertos o no.
    @State private var mostrarCarrete = false
    @State private var mostrarArchivos = false
    /// true mientras el revelado está en marcha (se muestra un indicador).
    @State private var revelando = false
    /// Mensaje de error a mostrar, o nil si no hay error.
    @State private var mensajeError: String? = nil

    /// Lado largo máximo de la PREVISUALIZACIÓN, en píxeles (§5.6). Cubre de
    /// sobra la pantalla del iPhone 17 Pro. La exportación (punto 6) irá
    /// siempre a resolución nativa completa, con el mismo código y escala 1.0.
    private let ladoLargoPrevisualizacion: CGFloat = 3000

    /// Tipos de archivo que aceptamos en "Archivos": cualquier RAW de cámara
    /// que iOS sepa revelar (incluye el .CR3 de la R6 Mark II y el DNG).
    private let tiposRAW: [UTType] = [.rawImage, UTType("com.adobe.raw-image")]
        .compactMap { $0 }

    var body: some View {
        ZStack {
            // El visor Metal ocupa todo, con fondo negro de sala de edición.
            VisorMetal(imagen: imagenRevelada)
                .ignoresSafeArea()
                .background(Color.black)

            // Aviso mientras no haya foto abierta.
            if imagenRevelada == nil && !revelando {
                VStack(spacing: 12) {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 56))
                        .foregroundStyle(.secondary)
                    Text("Revelado")
                        .font(.largeTitle.bold())
                        .foregroundStyle(.white)
                    Text("Abre un RAW con los botones de abajo.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            // Indicador mientras el revelado trabaja.
            if revelando {
                ProgressView("Revelando…")
                    .tint(.white)
                    .foregroundStyle(.white)
                    .padding(24)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .preferredColorScheme(.dark) // sala de edición: interfaz siempre oscura
        // La barra de botones, respetando el borde inferior de la pantalla.
        .safeAreaInset(edge: .bottom) { barraInferior }
        // Selector del carrete. preferredItemEncoding .current pide el archivo
        // ORIGINAL tal cual está guardado (el DNG), no una copia recomprimida.
        .photosPicker(isPresented: $mostrarCarrete,
                      selection: $seleccionCarrete,
                      matching: .images,
                      preferredItemEncoding: .current)
        // Selector de archivos sueltos, limitado a tipos RAW.
        .fileImporter(isPresented: $mostrarArchivos,
                      allowedContentTypes: tiposRAW) { resultado in
            abrirDesdeArchivos(resultado)
        }
        // Cuando el usuario elige algo en el carrete, se lanza el revelado.
        .onChange(of: seleccionCarrete) { _, nuevaSeleccion in
            guard let nuevaSeleccion else { return }
            Task { await abrirDesdeCarrete(nuevaSeleccion) }
        }
        // Aviso de error con el mensaje literal, para poder diagnosticar.
        .alert("No se pudo abrir la foto", isPresented: hayError) {
            Button("Entendido", role: .cancel) { mensajeError = nil }
        } message: {
            Text(mensajeError ?? "")
        }
    }

    /// Los dos botones de apertura.
    private var barraInferior: some View {
        HStack(spacing: 16) {
            Button {
                mostrarCarrete = true
            } label: {
                Label("Carrete", systemImage: "photo.on.rectangle")
            }
            Button {
                mostrarArchivos = true
            } label: {
                Label("Archivos", systemImage: "folder")
            }
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .padding(.vertical, 10)
    }

    /// Traduce "¿hay error?" al formato si/no que necesita el aviso.
    private var hayError: Binding<Bool> {
        Binding(get: { mensajeError != nil },
                set: { siHay in if !siHay { mensajeError = nil } })
    }

    // =========================================================================
    // Apertura desde el carrete de Fotos
    // =========================================================================
    @MainActor
    private func abrirDesdeCarrete(_ elemento: PhotosPickerItem) async {
        revelando = true
        defer {
            revelando = false
            seleccionCarrete = nil // listo para elegir otra foto después
        }
        do {
            // Pedimos los bytes del archivo original al carrete.
            guard let datos = try await elemento.loadTransferable(type: Data.self) else {
                mensajeError = "El carrete no entregó el archivo original."
                return
            }
            // Copia temporal con la extensión correcta, para que el revelador
            // sepa qué formato tiene delante.
            let extensionArchivo = elemento.supportedContentTypes.first?
                .preferredFilenameExtension ?? "dng"
            let urlTemporal = FileManager.default.temporaryDirectory
                .appendingPathComponent("carrete-\(UUID().uuidString)")
                .appendingPathExtension(extensionArchivo)
            try datos.write(to: urlTemporal)

            try await revelar(url: urlTemporal)
        } catch {
            mensajeError = error.localizedDescription
        }
    }

    // =========================================================================
    // Apertura desde el explorador de archivos
    // =========================================================================
    private func abrirDesdeArchivos(_ resultado: Result<URL, Error>) {
        Task { @MainActor in
            revelando = true
            defer { revelando = false }
            do {
                let urlElegida = try resultado.get()

                // El sistema entrega el archivo "precintado" (protección de
                // iOS): hay que abrir el precinto, copiarlo a nuestra carpeta
                // temporal y cerrarlo. El original queda intacto donde estaba.
                let precintoAbierto = urlElegida.startAccessingSecurityScopedResource()
                defer {
                    if precintoAbierto { urlElegida.stopAccessingSecurityScopedResource() }
                }

                let urlTemporal = FileManager.default.temporaryDirectory
                    .appendingPathComponent("archivo-\(UUID().uuidString)-\(urlElegida.lastPathComponent)")
                try FileManager.default.copyItem(at: urlElegida, to: urlTemporal)

                try await revelar(url: urlTemporal)
            } catch {
                mensajeError = error.localizedDescription
            }
        }
    }

    // =========================================================================
    // El revelado en sí, fuera del hilo principal para no congelar la interfaz
    // =========================================================================
    @MainActor
    private func revelar(url: URL) async throws {
        let ladoMaximo = ladoLargoPrevisualizacion
        // Task.detached = "llévate este trabajo al laboratorio de atrás":
        // el revelado tarda uno o dos segundos y la interfaz debe seguir viva.
        let imagen = try await Task.detached(priority: .userInitiated) {
            try MotorRevelado.compartido.decodificarRAWParaPantalla(
                en: url,
                ladoLargoMaximoPixeles: ladoMaximo)
        }.value
        imagenRevelada = imagen
    }
}

// Vista previa para el lienzo de Xcode (no forma parte de la app final).
#Preview {
    ContentView()
}
