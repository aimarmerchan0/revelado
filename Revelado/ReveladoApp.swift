// =============================================================================
// ReveladoApp.swift — el punto de entrada de la aplicación
//
// Todo programa necesita un "primer fotograma": el sitio exacto por donde
// empieza a ejecutarse. La marca @main de abajo le dice al sistema que es aquí.
// Lo único que hace es abrir una ventana y poner dentro la vista principal
// (ContentView).
// =============================================================================

import SwiftUI
import SwiftData

@main
struct ReveladoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        // Abre (o crea) la base de datos local de la biblioteca y la pone a
        // disposición de todas las pantallas.
        .modelContainer(for: Foto.self)
    }
}
