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
import CoreImage.CIFilterBuiltins

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

    /// Prepara el revelador RAW para EDICIÓN interactiva: se crea una vez por
    /// foto y se conserva mientras dura la sesión de edición, porque la
    /// temperatura y el matiz se ajustan en el propio revelado (mejor calidad
    /// que corregir después, §fase 2) y CIRAWFilter está hecho para eso.
    func filtroRAWParaEdicion(en url: URL,
                              ladoLargoMaximoPixeles: CGFloat) throws -> CIRAWFilter {
        let filtroRAW = try crearFiltroRAW(para: url)
        let tamanoNativo = filtroRAW.nativeSize
        let ladoLargo = max(tamanoNativo.width, tamanoNativo.height)
        filtroRAW.scaleFactor = ladoLargo > 0
            ? Float(min(1.0, ladoLargoMaximoPixeles / ladoLargo))
            : 1.0
        return filtroRAW
    }

    // =========================================================================
    // Exportación (§5.6, §5.7): MISMO código que la previsualización, con
    // factor de escala 1.0 — resolución nativa completa. Si fueran dos rutas
    // distintas, tarde o temprano lo exportado no sería lo que se veía.
    // =========================================================================

    /// Revela el original a resolución completa y le aplica la receta.
    func renderizarParaExportar(en url: URL, esRAW: Bool,
                                parametros: ParametrosEdicion) throws -> CIImage {
        let base: CIImage
        if esRAW {
            let filtroRAW = try crearFiltroRAW(para: url)
            filtroRAW.scaleFactor = 1.0 // resolución nativa completa
            // Mismo balance de blancos que en edición (§5.6).
            configurarBalanceBlancosRAW(en: filtroRAW, parametros: parametros)
            guard let imagen = filtroRAW.outputImage else {
                throw ErrorMotor.decodificacionFallida(url)
            }
            base = imagen
        } else {
            guard let imagen = CIImage(contentsOf: url,
                                       options: [.applyOrientationProperty: true]) else {
                throw ErrorMotor.decodificacionFallida(url)
            }
            base = aplicarBalanceBlancosNoRAW(a: imagen, parametros: parametros)
        }
        return aplicarAjustes(a: base, parametros: parametros)
    }

    /// TIFF de 16 bits por canal con perfil Display P3 incrustado (§5.7):
    /// el archivo maestro. Sin perfil incrustado sería un archivo roto.
    func exportarTIFF16(imagen: CIImage, a destino: URL) throws {
        try contexto.writeTIFFRepresentation(of: imagen,
                                             to: destino,
                                             format: .RGBA16,
                                             colorSpace: espacioSalidaPantalla,
                                             options: [:])
    }

    /// HEIF de 10 bits con perfil incrustado (§5.7): calidad alta y peso
    /// razonable, ideal para guardar en Fotos.
    func exportarHEIF10(imagen: CIImage, a destino: URL) throws {
        try contexto.writeHEIF10Representation(of: imagen,
                                               to: destino,
                                               colorSpace: espacioSalidaPantalla,
                                               options: [:])
    }

    // =========================================================================
    // La cadena de ajustes (fase 2): función PURA — misma entrada y mismos
    // parámetros dan siempre la misma salida. Solo construye la "receta"
    // (CIImage encadena filtros sin calcular nada); el render real ocurre una
    // única vez al dibujar (§5.4), en 16 bits y luz lineal (§5.1, §5.2).
    // =========================================================================

    /// Conversión del deslizador de temperatura a Kelvin: ±100 ≈ ±3500 K,
    /// suficiente para ir de tungsteno a sombra desde una base de luz día.
    static let kelvinPorUnidad: Double = 35
    /// Conversión del deslizador de matiz al eje verde-magenta.
    static let matizPorUnidad: Double = 0.4

    /// Balance de blancos para fotos NO RAW (las RAW lo hacen dentro del
    /// revelado vía neutralTemperature/neutralTint/neutralLocation).
    /// Primero el punto neutro del cuentagotas (si lo hay): el color
    /// muestreado se lleva a gris. Después, los ajustes finos de los
    /// deslizadores encima.
    func aplicarBalanceBlancosNoRAW(a origen: CIImage,
                                    parametros p: ParametrosEdicion) -> CIImage {
        var imagen = origen

        if let r = p.neutroR, let g = p.neutroG, let b = p.neutroB {
            let filtro = CIFilter.whitePointAdjust()
            filtro.inputImage = imagen
            filtro.color = CIColor(red: r, green: g, blue: b)
            imagen = filtro.outputImage ?? imagen
        }

        if p.temperatura != 0 || p.matiz != 0 {
            let filtro = CIFilter.temperatureAndTint()
            filtro.inputImage = imagen
            filtro.neutral = CIVector(x: 6500, y: 0)
            filtro.targetNeutral = CIVector(
                x: 6500 + CGFloat(p.temperatura * Self.kelvinPorUnidad),
                y: CGFloat(p.matiz * Self.matizPorUnidad))
            imagen = filtro.outputImage ?? imagen
        }
        return imagen
    }

    /// Configura el balance de blancos de un CIRAWFilter según la receta.
    /// Mismo código para previsualización y exportación (§5.6): el punto
    /// neutro va en coordenadas normalizadas, válidas a cualquier escala.
    func configurarBalanceBlancosRAW(en filtroRAW: CIRAWFilter,
                                     parametros p: ParametrosEdicion) {
        if let nx = p.puntoNeutroX, let ny = p.puntoNeutroY {
            let nativo = filtroRAW.nativeSize
            filtroRAW.neutralLocation = CGPoint(x: nx * nativo.width,
                                                y: ny * nativo.height)
        }
        // Ajuste fino de los deslizadores sobre el neutro actual
        // (el de cámara, o el del cuentagotas si se acaba de fijar).
        if p.temperatura != 0 || p.matiz != 0 {
            let baseT = filtroRAW.neutralTemperature
            let baseM = filtroRAW.neutralTint
            filtroRAW.neutralTemperature = baseT + Float(p.temperatura * Self.kelvinPorUnidad)
            filtroRAW.neutralTint = baseM + Float(p.matiz * Self.matizPorUnidad)
        }
    }

    /// Muestrea el color medio de una zona pequeña de la imagen (coordenada
    /// normalizada 0...1) y lo devuelve normalizado en brillo, listo para el
    /// cuentagotas de punto neutro en fotos no RAW.
    func colorNeutroMuestreado(en imagen: CIImage,
                               puntoNormalizado: CGPoint) -> (Double, Double, Double)? {
        let ext = imagen.extent
        let centroX = ext.origin.x + puntoNormalizado.x * ext.width
        let centroY = ext.origin.y + puntoNormalizado.y * ext.height
        let radio: CGFloat = 8
        let zona = CGRect(x: centroX - radio, y: centroY - radio,
                          width: radio * 2, height: radio * 2).intersection(ext)
        guard !zona.isEmpty else { return nil }

        let filtro = CIFilter.areaAverage()
        filtro.inputImage = imagen
        filtro.extent = zona
        guard let promedio = filtro.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        contexto.render(promedio, toBitmap: &pixel, rowBytes: 4,
                        bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                        format: .RGBA8, colorSpace: espacioSalidaPantalla)
        let r = Double(pixel[0]), g = Double(pixel[1]), b = Double(pixel[2])
        let maximo = max(r, g, b)
        guard maximo > 0 else { return nil } // zona negra pura: no sirve de neutro
        return (r / maximo, g / maximo, b / maximo)
    }

    /// Aplica la receta completa de tono y color sobre una imagen ya revelada.
    func aplicarAjustes(a origen: CIImage,
                        parametros p: ParametrosEdicion) -> CIImage {
        var imagen = origen

        // Exposición: en luz lineal, sumar EV es multiplicar por 2^EV,
        // exactamente como abrir el diafragma.
        if p.exposicion != 0 {
            let filtro = CIFilter.exposureAdjust()
            filtro.inputImage = imagen
            filtro.ev = Float(p.exposicion)
            imagen = filtro.outputImage ?? imagen
        }

        // Altas luces y sombras (recuperación).
        if p.altasLuces < 0 || p.sombras != 0 {
            let filtro = CIFilter.highlightShadowAdjust()
            filtro.inputImage = imagen
            // 1.0 = sin cambio; hacia 0.3 = recuperar altas luces.
            filtro.highlightAmount = p.altasLuces < 0
                ? Float(1.0 + p.altasLuces / 100.0 * 0.7)
                : 1.0
            // 0 = sin cambio; +1 abre sombras, -1 las cierra.
            filtro.shadowAmount = Float(p.sombras / 100.0)
            imagen = filtro.outputImage ?? imagen
        }

        // Altas luces en positivo (realzar): pequeña subida del tramo alto
        // de la curva. (Se refinará con kernel propio más adelante.)
        if p.altasLuces > 0 {
            let filtro = CIFilter.toneCurve()
            filtro.inputImage = imagen
            filtro.point0 = CGPoint(x: 0, y: 0)
            filtro.point1 = CGPoint(x: 0.25, y: 0.25)
            filtro.point2 = CGPoint(x: 0.5, y: 0.5)
            filtro.point3 = CGPoint(x: 0.75, y: 0.75 + p.altasLuces / 100.0 * 0.12)
            filtro.point4 = CGPoint(x: 1, y: 1)
            imagen = filtro.outputImage ?? imagen
        }

        // Blancos (ganancia del punto blanco) y negros (desplazamiento del
        // punto negro), como mover los extremos de la escala.
        if p.blancos != 0 || p.negros != 0 {
            let ganancia = CGFloat(1.0 + p.blancos / 100.0 * 0.25)
            let sesgo = CGFloat(p.negros / 100.0 * 0.06)
            let filtro = CIFilter.colorMatrix()
            filtro.inputImage = imagen
            filtro.rVector = CIVector(x: ganancia, y: 0, z: 0, w: 0)
            filtro.gVector = CIVector(x: 0, y: ganancia, z: 0, w: 0)
            filtro.bVector = CIVector(x: 0, y: 0, z: ganancia, w: 0)
            filtro.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            filtro.biasVector = CIVector(x: sesgo, y: sesgo, z: sesgo, w: 0)
            imagen = filtro.outputImage ?? imagen

            // Si se empastan negros (sesgo negativo) evitamos valores por
            // debajo de cero, que no tienen sentido físico. Por arriba NO se
            // recorta: las altas luces extendidas se conservan (§5.8).
            if sesgo < 0 {
                let clamp = CIFilter.colorClamp()
                clamp.inputImage = imagen
                clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
                clamp.maxComponents = CIVector(x: 65504, y: 65504, z: 65504, w: 65504)
                imagen = clamp.outputImage ?? imagen
            }
        }

        // Contraste y saturación global.
        if p.contraste != 0 || p.saturacion != 0 {
            let filtro = CIFilter.colorControls()
            filtro.inputImage = imagen
            filtro.contrast = Float(1.0 + p.contraste / 100.0 * 0.5)
            filtro.saturation = Float(1.0 + p.saturacion / 100.0)
            filtro.brightness = 0
            imagen = filtro.outputImage ?? imagen
        }

        // Intensidad (vibrance): satura protegiendo lo que ya está saturado
        // y los tonos de piel.
        if p.intensidad != 0 {
            let filtro = CIFilter.vibrance()
            filtro.inputImage = imagen
            filtro.amount = Float(p.intensidad / 100.0)
            imagen = filtro.outputImage ?? imagen
        }

        return imagen
    }
}
