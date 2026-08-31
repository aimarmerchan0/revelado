// =============================================================================
// ContentView.swift — la galería: la pantalla principal de la app
//
// Cuadrícula con las miniaturas de la biblioteca, un filtro por formato
// (Todas / RAW / Otras) y los dos botones de importación: el carrete de Fotos
// y el explorador de Archivos (que admite elegir varios a la vez).
// Tocar una foto abre su mesa de revelado (EditorView).
// =============================================================================

import SwiftUI
import SwiftData
import PhotosUI

struct ContentView: View {

    /// El "archivador" de SwiftData donde se guardan y leen las fichas.
    @Environment(\.modelContext) private var contexto
    /// Todas las fotos de la biblioteca, las más recientes primero.
    /// @Query mantiene la lista al día sola: al importar, la galería se
    /// refresca sin que hagamos nada.
    @Query(sort: \Foto.fechaImportacion, order: .reverse) private var fotos: [Foto]

    /// El filtro de formato elegido.
    enum Filtro: String, CaseIterable, Identifiable {
        case todas = "Todas"
        case raw = "RAW"
        case otras = "Otras"
        var id: String { rawValue }
    }

    @State private var filtro: Filtro = .todas
    @State private var seleccionCarrete: PhotosPickerItem? = nil
    @State private var mostrarCarrete = false
    @State private var mostrarArchivos = false
    @State private var importando = false
    @State private var mensajeError: String? = nil
    /// Foto pendiente de confirmación de borrado.
    @State private var fotoAEliminar: Foto? = nil

    private var fotosFiltradas: [Foto] {
        switch filtro {
        case .todas: return fotos
        case .raw: return fotos.filter { $0.esRAW }
        case .otras: return fotos.filter { !$0.esRAW }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Formato", selection: $filtro) {
                    ForEach(Filtro.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                if fotosFiltradas.isEmpty {
                    // El estado vacío estándar de iOS 17.
                    if fotos.isEmpty {
                        ContentUnavailableView {
                            Label("Sin fotos", systemImage: "camera.aperture")
                        } description: {
                            Text("Importa tus RAW y fotos con el botón +.")
                        } actions: {
                            Button("Importar de Archivos") { mostrarArchivos = true }
                                .buttonStyle(.borderedProminent)
                        }
                    } else {
                        ContentUnavailableView("Nada con este formato",
                                               systemImage: "line.3.horizontal.decrease.circle",
                                               description: Text("Prueba con otro filtro."))
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110),
                                                     spacing: 2)],
                                  spacing: 2) {
                            ForEach(fotosFiltradas) { foto in
                                NavigationLink {
                                    EditorView(foto: foto)
                                } label: {
                                    CeldaFoto(foto: foto)
                                }
                                .buttonStyle(.plain)
                                // Mantener pulsada una miniatura: opciones.
                                .contextMenu {
                                    Button(role: .destructive) {
                                        fotoAEliminar = foto
                                    } label: {
                                        Label("Eliminar de la biblioteca",
                                              systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Revelado")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if importando {
                        ProgressView()
                    }
                    // El patrón estándar de Apple: un único botón + con menú.
                    Menu {
                        Button {
                            mostrarCarrete = true
                        } label: {
                            Label("Del carrete", systemImage: "photo.on.rectangle")
                        }
                        Button {
                            mostrarArchivos = true
                        } label: {
                            Label("De Archivos", systemImage: "folder")
                        }
                    } label: {
                        Label("Importar", systemImage: "plus")
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        // Carrete: pide el archivo ORIGINAL (.current), no una copia comprimida.
        .photosPicker(isPresented: $mostrarCarrete,
                      selection: $seleccionCarrete,
                      matching: .images,
                      preferredItemEncoding: .current)
        // Archivos: cualquier imagen (RAW o no), varios a la vez.
        .fileImporter(isPresented: $mostrarArchivos,
                      allowedContentTypes: [.image, .rawImage],
                      allowsMultipleSelection: true) { resultado in
            importarDesdeArchivos(resultado)
        }
        .onChange(of: seleccionCarrete) { _, nuevaSeleccion in
            guard let nuevaSeleccion else { return }
            Task { await importarDesdeCarrete(nuevaSeleccion) }
        }
        .alert("No se pudo importar", isPresented: hayError) {
            Button("Entendido", role: .cancel) { mensajeError = nil }
        } message: {
            Text(mensajeError ?? "")
        }
        // Confirmación antes de borrar: se pierde la copia de la biblioteca
        // y su edición (el archivo de origen fuera de la app no se toca).
        .confirmationDialog(
            "¿Eliminar \(fotoAEliminar?.nombreOriginal ?? "esta foto")?",
            isPresented: Binding(get: { fotoAEliminar != nil },
                                 set: { si in if !si { fotoAEliminar = nil } }),
            titleVisibility: .visible
        ) {
            Button("Eliminar de la biblioteca", role: .destructive) {
                if let foto = fotoAEliminar { eliminar(foto) }
                fotoAEliminar = nil
            }
            Button("Cancelar", role: .cancel) { fotoAEliminar = nil }
        } message: {
            Text("Se borra la copia de la biblioteca y su edición. El archivo original de donde la importaste no se toca.")
        }
    }

    /// Borra la copia del original de la carpeta de la biblioteca y su ficha.
    private func eliminar(_ foto: Foto) {
        if let url = try? Biblioteca.urlOriginal(de: foto) {
            try? FileManager.default.removeItem(at: url)
        }
        contexto.delete(foto)
    }

    private var hayError: Binding<Bool> {
        Binding(get: { mensajeError != nil },
                set: { siHay in if !siHay { mensajeError = nil } })
    }

    // =========================================================================
    // Importación desde el carrete
    // =========================================================================
    @MainActor
    private func importarDesdeCarrete(_ elemento: PhotosPickerItem) async {
        importando = true
        defer {
            importando = false
            seleccionCarrete = nil
        }
        do {
            guard let datos = try await elemento.loadTransferable(type: Data.self) else {
                mensajeError = "El carrete no entregó el archivo original."
                return
            }
            let tipo = elemento.supportedContentTypes.first
            let ext = tipo?.preferredFilenameExtension ?? "dng"
            let nombre = "Carrete \(Date().formatted(date: .abbreviated, time: .shortened))"
            // La copia y la miniatura son trabajo pesado: al laboratorio de atrás.
            let ficha = try await Task.detached(priority: .userInitiated) {
                try Biblioteca.importar(datos: datos,
                                        nombreOriginal: nombre,
                                        extensionArchivo: ext)
            }.value
            contexto.insert(ficha)
        } catch {
            mensajeError = error.localizedDescription
        }
    }

    // =========================================================================
    // Importación desde el explorador de Archivos (admite varios)
    // =========================================================================
    private func importarDesdeArchivos(_ resultado: Result<[URL], Error>) {
        Task { @MainActor in
            importando = true
            defer { importando = false }
            do {
                let urls = try resultado.get()
                var fallos: [String] = []
                for url in urls {
                    // Abrir el "precinto" de seguridad de iOS, copiar, cerrar.
                    let precintoAbierto = url.startAccessingSecurityScopedResource()
                    defer {
                        if precintoAbierto { url.stopAccessingSecurityScopedResource() }
                    }
                    do {
                        let ficha = try await Task.detached(priority: .userInitiated) {
                            try Biblioteca.importar(desde: url)
                        }.value
                        contexto.insert(ficha)
                    } catch {
                        fallos.append(url.lastPathComponent)
                    }
                }
                if !fallos.isEmpty {
                    mensajeError = "No se pudieron importar: \(fallos.joined(separator: ", "))"
                }
            } catch {
                mensajeError = error.localizedDescription
            }
        }
    }
}

/// Una celda de la cuadrícula: miniatura cuadrada con etiqueta de formato.
private struct CeldaFoto: View {
    let foto: Foto

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color(.systemGray6)
                .aspectRatio(1, contentMode: .fill)
                .overlay {
                    if let datos = foto.miniatura, let ui = UIImage(data: datos) {
                        Image(uiImage: ui)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "photo")
                            .font(.title)
                            .foregroundStyle(.secondary)
                    }
                }
                .clipped()

            Text(foto.esRAW ? "RAW" : foto.extensionArchivo.uppercased())
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.65), in: Capsule())
                .foregroundStyle(.white)
                .padding(4)
        }
        .contentShape(Rectangle())
    }
}

// Vista previa para el lienzo de Xcode (no forma parte de la app final).
#Preview {
    ContentView()
        .modelContainer(for: Foto.self, inMemory: true)
}
