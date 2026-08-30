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
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "camera.aperture")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text(fotos.isEmpty
                             ? "Biblioteca vacía.\nImporta fotos con los botones de arriba."
                             : "No hay fotos de este formato.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
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
