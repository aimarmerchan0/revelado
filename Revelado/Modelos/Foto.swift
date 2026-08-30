// =============================================================================
// Foto.swift — la ficha de cada foto en la biblioteca
//
// Cada foto importada tiene una ficha como esta, guardada con SwiftData (la
// base de datos local de la app). La ficha NO contiene la imagen: contiene
// dónde está el original dentro de la biblioteca, una miniatura pequeña para
// la galería, y (en el futuro inmediato) los parámetros de edición.
//
// Regla §5.5: el original nunca se toca. Editar = guardar parámetros aquí.
// Deshacer = volver a parámetros anteriores. Borrar la edición = el original
// sigue intacto en su carpeta.
// =============================================================================

import Foundation
import SwiftData

@Model
final class Foto {
    /// Identificador único de la ficha.
    @Attribute(.unique) var id: UUID
    /// El nombre que tenía el archivo al importarlo (p. ej. IMG_0421.CR3).
    var nombreOriginal: String
    /// La extensión en minúsculas (cr3, dng, jpg, heic...).
    var extensionArchivo: String
    /// true si es un RAW (CR3, DNG...); false para JPEG, HEIC, TIFF, etc.
    var esRAW: Bool
    /// Cuándo se importó.
    var fechaImportacion: Date
    /// Ruta del original DENTRO de la carpeta de la biblioteca de la app
    /// (solo el nombre de archivo; la carpeta la conoce Biblioteca.swift).
    /// No se guarda una ruta absoluta porque iOS puede cambiar la ruta de la
    /// app entre actualizaciones; lo estable es la ruta relativa.
    var rutaRelativa: String
    /// Miniatura JPEG pequeña para la cuadrícula de la galería.
    /// (Es solo un "contacto" de catálogo, como los de una hoja de contactos:
    /// la edición y la exportación SIEMPRE parten del original, así que la
    /// regla §5.1 del pipeline no se ve afectada.)
    @Attribute(.externalStorage) var miniatura: Data?
    /// Los parámetros de edición, codificados como JSON (fase 2).
    /// nil = sin ediciones todavía.
    var parametrosJSON: Data?

    init(nombreOriginal: String,
         extensionArchivo: String,
         esRAW: Bool,
         rutaRelativa: String,
         miniatura: Data?) {
        self.id = UUID()
        self.nombreOriginal = nombreOriginal
        self.extensionArchivo = extensionArchivo
        self.esRAW = esRAW
        self.fechaImportacion = Date()
        self.rutaRelativa = rutaRelativa
        self.miniatura = miniatura
        self.parametrosJSON = nil
    }
}
