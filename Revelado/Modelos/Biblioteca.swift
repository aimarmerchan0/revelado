// =============================================================================
// Biblioteca.swift — el archivador físico de originales
//
// Decisión importante: al importar, el archivo se COPIA a una carpeta propia
// de la app (Documentos/Originales). No guardamos solo la ruta o un acceso
// directo al archivo de origen, porque si luego mueves o borras ese archivo
// de iCloud/Archivos, la foto de la biblioteca quedaría rota. Con copia
// propia, el original queda a salvo dentro de la app, pase lo que pase fuera.
// El precio es espacio en disco (un RAW de la R6 II son ~25-40 MB).
// =============================================================================

import Foundation
import CoreImage
import UIKit
import UniformTypeIdentifiers

enum ErrorBiblioteca: Error, LocalizedError {
    case copiaFallida(String)

    var errorDescription: String? {
        switch self {
        case .copiaFallida(let nombre):
            return "No se pudo copiar \(nombre) a la biblioteca."
        }
    }
}

struct Biblioteca {

    /// Lado largo de las miniaturas de la galería, en píxeles.
    static let ladoMiniatura: CGFloat = 512

    /// La carpeta Documentos/Originales, creándola si no existe.
    static func carpetaOriginales() throws -> URL {
        let docs = try FileManager.default.url(for: .documentDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil,
                                               create: true)
        let carpeta = docs.appendingPathComponent("Originales", isDirectory: true)
        try FileManager.default.createDirectory(at: carpeta,
                                                withIntermediateDirectories: true)
        return carpeta
    }

    /// Ruta completa del original de una foto de la biblioteca.
    static func urlOriginal(de foto: Foto) throws -> URL {
        try carpetaOriginales().appendingPathComponent(foto.rutaRelativa)
    }

    /// ¿Esta extensión corresponde a un RAW que iOS sabe revelar?
    static func esRAW(extensionArchivo: String) -> Bool {
        guard let tipo = UTType(filenameExtension: extensionArchivo.lowercased()) else {
            return false
        }
        return tipo.conforms(to: .rawImage)
    }

    /// Importa un archivo del que ya tenemos los bytes (caso del carrete).
    static func importar(datos: Data, nombreOriginal: String,
                         extensionArchivo: String) throws -> Foto {
        let ext = extensionArchivo.lowercased()
        let rutaRelativa = "\(UUID().uuidString).\(ext)"
        let destino = try carpetaOriginales().appendingPathComponent(rutaRelativa)
        try datos.write(to: destino)
        return crearFicha(nombre: nombreOriginal, ext: ext,
                          rutaRelativa: rutaRelativa, url: destino)
    }

    /// Importa un archivo desde una URL de fuera (caso del explorador de
    /// Archivos). Quien llama se encarga de abrir el "precinto" de seguridad.
    static func importar(desde origen: URL) throws -> Foto {
        let ext = origen.pathExtension.lowercased()
        let rutaRelativa = "\(UUID().uuidString).\(ext)"
        let destino = try carpetaOriginales().appendingPathComponent(rutaRelativa)
        do {
            try FileManager.default.copyItem(at: origen, to: destino)
        } catch {
            throw ErrorBiblioteca.copiaFallida(origen.lastPathComponent)
        }
        return crearFicha(nombre: origen.lastPathComponent, ext: ext,
                          rutaRelativa: rutaRelativa, url: destino)
    }

    private static func crearFicha(nombre: String, ext: String,
                                   rutaRelativa: String, url: URL) -> Foto {
        let raw = esRAW(extensionArchivo: ext)
        let miniatura = generarMiniatura(url: url, esRAW: raw)
        return Foto(nombreOriginal: nombre,
                    extensionArchivo: ext,
                    esRAW: raw,
                    rutaRelativa: rutaRelativa,
                    miniatura: miniatura)
    }

    /// Genera la miniatura JPEG de la galería revelando el archivo en pequeño.
    /// Si algo falla devuelve nil y la galería enseña un marcador de posición:
    /// una miniatura rota nunca debe impedir importar la foto.
    static func generarMiniatura(url: URL, esRAW: Bool) -> Data? {
        guard let imagen = try? MotorRevelado.compartido.cargarParaPantalla(
            en: url, esRAW: esRAW, ladoLargoMaximoPixeles: ladoMiniatura)
        else { return nil }

        // Aquí sí convertimos a imagen corriente de 8 bits: es solo el
        // "contacto" del catálogo. La cadena de edición jamás pasa por aquí.
        guard let cg = MotorRevelado.compartido.contexto.createCGImage(
            imagen, from: imagen.extent, format: .RGBA8,
            colorSpace: MotorRevelado.compartido.espacioSalidaPantalla)
        else { return nil }

        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.85)
    }
}
