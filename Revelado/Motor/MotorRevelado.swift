// =============================================================================
// MotorRevelado.swift — el corazón de la app: el laboratorio de revelado
//
// Aquí vive el CIContext, que es el "cuarto oscuro" donde ocurre todo el
// procesado de imagen, y la función que abre un archivo RAW (ProRAW del
// iPhone o .CR3 de la Canon R6 Mark II) y lo revela a imagen.
//
// Este archivo implementa las reglas de calidad de la §5 del documento del
// proyecto. Cualquier cambio que las relaje está mal aunque funcione:
//
//   §5.1  Nunca 8 bits: se trabaja en half float (16 bits por canal).
//   §5.2  Todo el cálculo en luz LINEAL y gamut amplio, no en valores con
//         gamma. Sumar exposición con gamma ensucia las transiciones.
//   §5.8  El recorte de gamut desactivado al decodificar, para no tirar
//         información de altas luces saturadas.
//   §5.9  Sin caché de pasos intermedios, para que la memoria no se dispare
//         con archivos de 24-48 megapíxeles.
// =============================================================================

import CoreImage

/// Errores que el motor puede comunicar, con mensaje en claro.
enum ErrorMotor: Error, LocalizedError {
    /// El archivo no es un RAW que iOS sepa revelar (o no es un RAW).
    case formatoNoSoportado(URL)
    /// El RAW se abrió pero el revelado no produjo imagen.
    case decodificacionFallida(URL)

    var errorDescription: String? {
        switch self {
        case .formatoNoSoportado(let url):
            return "iOS no sabe revelar este archivo: \(url.lastPathComponent)"
        case .decodificacionFallida(let url):
            return "El revelado de \(url.lastPathComponent) no produjo imagen."
        }
    }
}

/// El laboratorio de revelado. Hay uno solo para toda la app (crear un
/// CIContext es caro, como montar un cuarto oscuro: se monta una vez).
final class MotorRevelado {

    /// La instancia única que usa toda la app.
    static let compartido = MotorRevelado()

    /// El "cuarto oscuro": donde Core Image ejecuta la cadena de ajustes
    /// en la GPU. Configurado según la §5 — ver el init.
    let contexto: CIContext

    /// Espacio de color de SALIDA para pantalla: Display P3 (§5.3).
    /// Los iPhone modernos lo cubren entero; recortar a sRGB sería tirar
    /// color que sí existe en la foto.
    let espacioSalidaPantalla = CGColorSpace(name: CGColorSpace.displayP3)!

    private init() {
        // §5.2 — Espacio de TRABAJO: sRGB lineal extendido. "Lineal" significa
        // que los números son proporcionales a la luz real, como en el negativo;
        // "extendido" significa que admite valores fuera de rango sin recortar,
        // igual que un RAW guarda altas luces por encima del blanco nominal.
        let espacioTrabajo = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

        contexto = CIContext(options: [
            // §5.1 — RGBAh = half float, 16 bits por canal. RGBA8 prohibido.
            .workingFormat: CIFormat.RGBAh,
            .workingColorSpace: espacioTrabajo,
            // §5.9 — sin caché de pasos intermedios: menos memoria.
            .cacheIntermediates: false,
            .name: "MotorRevelado",
        ])
    }

    /// Prepara el revelador de Apple para un archivo RAW concreto.
    /// CIRAWFilter entiende el RAW de cada cámara de su lista de
    /// compatibilidad (la R6 Mark II está en ella; el ProRAW es nativo).
    private func crearFiltroRAW(para url: URL) throws -> CIRAWFilter {
        guard let filtroRAW = CIRAWFilter(imageURL: url) else {
            throw ErrorMotor.formatoNoSoportado(url)
        }
        // §5.8 — NO recortar los colores fuera de gamut al decodificar.
        // Si hiciera falta mapear gamut, se hará al final de la cadena.
        filtroRAW.isGamutMappingEnabled = false
        return filtroRAW
    }

    /// Abre un archivo RAW y lo revela con los ajustes neutros de Apple,
    /// sin ningún ajuste nuestro todavía (eso llega en la fase 2).
    ///
    /// - Parámetros:
    ///   - url: la ruta del archivo RAW (DNG del iPhone o CR3 de la Canon).
    ///   - factorEscala: 1.0 = resolución nativa completa (exportación);
    ///     valores menores = revelado reducido para previsualizar (§5.6).
    ///     Es el MISMO camino de código en ambos casos: solo cambia este número.
    /// - Devuelve: la imagen revelada como CIImage (todavía sin renderizar:
    ///   es la "receta" de la imagen, lista para encadenar ajustes encima).
    func decodificarRAW(en url: URL, factorEscala: Float = 1.0) throws -> CIImage {
        let filtroRAW = try crearFiltroRAW(para: url)

        // §5.6 — misma decodificación para preview y export; solo varía escala.
        filtroRAW.scaleFactor = factorEscala

        guard let imagen = filtroRAW.outputImage else {
            throw ErrorMotor.decodificacionFallida(url)
        }
        return imagen
    }

    /// Igual que decodificarRAW, pero calcula solo el factor de escala para
    /// que el lado largo de la imagen no pase de un máximo en píxeles (§5.6:
    /// previsualización reducida al tamaño real de pantalla, nunca ampliada
    /// por encima del 100%).
    func decodificarRAWParaPantalla(en url: URL,
                                    ladoLargoMaximoPixeles: CGFloat) throws -> CIImage {
        let filtroRAW = try crearFiltroRAW(para: url)

        let tamanoNativo = filtroRAW.nativeSize
        let ladoLargo = max(tamanoNativo.width, tamanoNativo.height)
        filtroRAW.scaleFactor = ladoLargo > 0
            ? Float(min(1.0, ladoLargoMaximoPixeles / ladoLargo))
            : 1.0

        guard let imagen = filtroRAW.outputImage else {
            throw ErrorMotor.decodificacionFallida(url)
        }
        return imagen
    }

    /// Carga cualquier imagen de la biblioteca para mostrarla en pantalla:
    /// los RAW pasan por el revelador (CIRAWFilter); los demás formatos
    /// (JPEG, HEIC, TIFF...) se abren directamente, respetando la orientación
    /// de la cámara, y se reducen si superan el lado máximo pedido.
    func cargarParaPantalla(en url: URL, esRAW: Bool,
                            ladoLargoMaximoPixeles: CGFloat) throws -> CIImage {
        if esRAW {
            return try decodificarRAWParaPantalla(
                en: url, ladoLargoMaximoPixeles: ladoLargoMaximoPixeles)
        }

        guard let imagen = CIImage(contentsOf: url,
                                   options: [.applyOrientationProperty: true]) else {
            throw ErrorMotor.decodificacionFallida(url)
        }
        let ladoLargo = max(imagen.extent.width, imagen.extent.height)
        if ladoLargo > ladoLargoMaximoPixeles, ladoLargo > 0 {
            let factor = ladoLargoMaximoPixeles / ladoLargo
            return imagen.transformed(by: .init(scaleX: factor, y: factor))
        }
        return imagen
    }
}
