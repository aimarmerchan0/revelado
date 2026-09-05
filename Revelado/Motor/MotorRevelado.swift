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
import Vision
import ImageIO

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
            // Mismo revelado que en edición (§5.6): balance, exposición,
            // ruido y enfoque a nivel de sensor.
            let bases = leerBasesRAW(filtroRAW)
            configurarReveladoRAW(en: filtroRAW, bases: bases, parametros: parametros)
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
        let cubo = parametros.hslEsNeutro
            ? nil
            : ProcesadoColor.generarCuboHSL(parametros.hsl)
        // Las selecciones se recalculan sobre la imagen a resolución
        // completa, para que las máscaras exportadas tengan el máximo detalle.
        var mascaras = Mascaras()
        if parametros.usaSelecciones {
            if parametros.realceSujeto != 0 || parametros.realceFondo != 0
                || parametros.saturacionSujeto != 0 || parametros.saturacionFondo != 0 {
                mascaras.sujeto = mascaraSujeto(de: base)
            }
            if parametros.luzCielo != 0 || parametros.saturacionCielo != 0 {
                mascaras.cielo = mascaraHeuristica(de: base, zona: .cielo)
            }
            if parametros.luzVerdes != 0 || parametros.saturacionVerdes != 0 {
                mascaras.vegetacion = mascaraHeuristica(de: base, zona: .vegetacion)
            }
        }
        return aplicarAjustes(a: base, parametros: parametros,
                              cuboHSL: cubo, mascaras: mascaras,
                              decodificadoRAW: esRAW)
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

    /// JPEG a calidad máxima con perfil incrustado (§5.7): para compartir
    /// donde el HEIF o el TIFF no entran.
    func exportarJPEG(imagen: CIImage, a destino: URL) throws {
        try contexto.writeJPEGRepresentation(
            of: imagen, to: destino,
            colorSpace: espacioSalidaPantalla,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 1.0])
    }

    // =========================================================================
    // Metadatos EXIF del original: la ficha técnica de la toma.
    // =========================================================================
    func leerMetadatos(de url: URL) -> [(String, String)] {
        guard let fuente = CGImageSourceCreateWithURL(url as CFURL, nil),
              let propiedades = CGImageSourceCopyPropertiesAtIndex(fuente, 0, nil)
                as? [CFString: Any] else { return [] }

        let exif = propiedades[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = propiedades[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]

        var filas: [(String, String)] = []

        if let marca = tiff[kCGImagePropertyTIFFMake] as? String,
           let modelo = tiff[kCGImagePropertyTIFFModel] as? String {
            filas.append(("Cámara", "\(marca) \(modelo)"))
        } else if let modelo = tiff[kCGImagePropertyTIFFModel] as? String {
            filas.append(("Cámara", modelo))
        }
        if let lente = exif[kCGImagePropertyExifLensModel] as? String {
            filas.append(("Objetivo", lente))
        }
        if let ancho = propiedades[kCGImagePropertyPixelWidth] as? Int,
           let alto = propiedades[kCGImagePropertyPixelHeight] as? Int {
            let megapixeles = Double(ancho * alto) / 1_000_000
            filas.append(("Dimensiones",
                          "\(ancho) × \(alto) (\(String(format: "%.1f", megapixeles)) Mpx)"))
        }
        if let isos = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int],
           let iso = isos.first {
            filas.append(("ISO", "\(iso)"))
        }
        if let tiempo = exif[kCGImagePropertyExifExposureTime] as? Double, tiempo > 0 {
            filas.append(("Obturación", tiempo >= 1
                          ? String(format: "%.1f s", tiempo)
                          : "1/\(Int((1 / tiempo).rounded())) s"))
        }
        if let apertura = exif[kCGImagePropertyExifFNumber] as? Double {
            filas.append(("Diafragma", String(format: "f/%.1f", apertura)))
        }
        if let focal = exif[kCGImagePropertyExifFocalLength] as? Double {
            filas.append(("Focal", String(format: "%.0f mm", focal)))
        }
        if let fecha = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            filas.append(("Fecha de captura", fecha))
        }
        return filas
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

    /// Los valores con los que el revelador abrió el RAW por primera vez:
    /// el punto de partida de todos los ajustes de nivel de revelado.
    struct BasesRAW {
        var temperatura: Float
        var tinte: Float
        var exposicion: Float
        var ruidoLuminancia: Float
        var ruidoColor: Float
        var nitidez: Float
    }

    /// Lee las bases de un filtro recién creado, ANTES de tocar nada.
    func leerBasesRAW(_ filtroRAW: CIRAWFilter) -> BasesRAW {
        BasesRAW(temperatura: filtroRAW.neutralTemperature,
                 tinte: filtroRAW.neutralTint,
                 exposicion: filtroRAW.exposure,
                 ruidoLuminancia: filtroRAW.luminanceNoiseReductionAmount,
                 ruidoColor: filtroRAW.colorNoiseReductionAmount,
                 nitidez: filtroRAW.sharpnessAmount)
    }

    /// Configura el revelado RAW completo según la receta, partiendo siempre
    /// de las bases: balance de blancos, exposición, reducción de ruido y
    /// enfoque se ejecutan DENTRO del revelador, sobre los datos del sensor,
    /// que es donde mejor calidad dan. Mismo código para previsualización y
    /// exportación (§5.6): se llama con el mismo par (filtro, receta).
    func configurarReveladoRAW(en filtroRAW: CIRAWFilter,
                               bases: BasesRAW,
                               parametros p: ParametrosEdicion) {
        // Volver al punto de partida (el filtro persiste entre pasadas).
        filtroRAW.neutralTemperature = bases.temperatura
        filtroRAW.neutralTint = bases.tinte
        configurarBalanceBlancosRAW(en: filtroRAW, parametros: p)

        // Exposición a nivel de revelado: pasos EV reales sobre el sensor.
        filtroRAW.exposure = bases.exposicion + Float(p.exposicion)

        // Reducción de ruido del propio revelador (trabaja antes del
        // demosaicado final: mucho más limpia que un filtro posterior).
        filtroRAW.luminanceNoiseReductionAmount =
            min(1, max(0, bases.ruidoLuminancia + Float(p.reduccionRuido / 100)))
        filtroRAW.colorNoiseReductionAmount =
            min(1, max(0, bases.ruidoColor + Float(p.reduccionRuidoColor / 100)))

        // Enfoque del revelador, sobre el detalle real del sensor.
        filtroRAW.sharpnessAmount =
            min(1, max(0, bases.nitidez + Float(p.enfoque / 100)))
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

    /// El mecanismo compartido de las cuatro bandas tonales: construye una
    /// máscara de luminosidad (la rampa dice qué tonos entran y con cuánta
    /// caída), aplica exposición real dentro de la banda y funde con el
    /// original. La rampa se evalúa en términos perceptuales (sRGB), donde
    /// 0.5 es el gris medio que ve el ojo.
    private func ajusteBandaTonal(_ origen: CIImage, ev: Double,
                                  rampa: [PuntoCurva]) -> CIImage {
        guard ev != 0 else { return origen }

        // 1) Luminosidad de cada píxel, en gris.
        let luma = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        let gris = CIFilter.colorMatrix()
        gris.inputImage = origen
        gris.rVector = luma
        gris.gVector = luma
        gris.bVector = luma
        gris.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        var mascara = gris.outputImage ?? origen

        // 2) La rampa de la banda, con transición suave.
        let curva = CIFilter.colorCurves()
        curva.inputImage = mascara
        curva.curvesData = ProcesadoColor.datosCurvaUnica(rampa)
        curva.curvesDomain = CIVector(x: 0, y: 1)
        curva.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        mascara = curva.outputImage ?? mascara

        // 3) Exposición dentro de la banda y fundido con el original.
        let expuesta = CIFilter.exposureAdjust()
        expuesta.inputImage = origen
        expuesta.ev = Float(ev)
        guard let ajustada = expuesta.outputImage else { return origen }

        let fusion = CIFilter.blendWithMask()
        fusion.inputImage = ajustada
        fusion.backgroundImage = origen
        fusion.maskImage = mascara
        return fusion.outputImage ?? origen
    }

    /// Caché de tablas de color de los looks (se cargan del paquete una vez).
    private static var lutsCargadas: [String: Data] = [:]

    /// Carga la LUT de un look desde los recursos de la app.
    func cargarLUT(_ nombre: String) -> Data? {
        if let datos = Self.lutsCargadas[nombre] { return datos }
        guard let url = Bundle.main.url(forResource: nombre, withExtension: "dat"),
              let datos = try? Data(contentsOf: url) else { return nil }
        Self.lutsCargadas[nombre] = datos
        return datos
    }

    /// El mecanismo del viraje partido: tiñe una banda tonal (definida por la
    /// rampa) hacia cálido (+) o frío (-), desplazando rojo y azul en
    /// direcciones opuestas y fundiendo con la máscara de la banda.
    private func aplicarViraje(_ origen: CIImage, cantidad: Double,
                               rampa: [PuntoCurva]) -> CIImage {
        guard cantidad != 0 else { return origen }

        // Máscara de la banda (misma técnica que las bandas tonales).
        let luma = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        let gris = CIFilter.colorMatrix()
        gris.inputImage = origen
        gris.rVector = luma; gris.gVector = luma; gris.bVector = luma
        gris.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        var mascara = gris.outputImage ?? origen
        let curva = CIFilter.colorCurves()
        curva.inputImage = mascara
        curva.curvesData = ProcesadoColor.datosCurvaUnica(rampa)
        curva.curvesDomain = CIVector(x: 0, y: 1)
        curva.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        mascara = curva.outputImage ?? mascara

        // La versión teñida: +cálido = rojo arriba y azul abajo; -frío al revés.
        let k = CGFloat(cantidad / 100.0)
        let tenida = CIFilter.colorMatrix()
        tenida.inputImage = origen
        tenida.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        tenida.gVector = CIVector(x: 0, y: 1, z: 0, w: 0)
        tenida.bVector = CIVector(x: 0, y: 0, z: 1, w: 0)
        tenida.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        tenida.biasVector = CIVector(x: 0.045 * k, y: 0.008 * k, z: -0.05 * k, w: 0)
        guard let ajustada = tenida.outputImage else { return origen }

        let fusion = CIFilter.blendWithMask()
        fusion.inputImage = ajustada
        fusion.backgroundImage = origen
        fusion.maskImage = mascara
        return fusion.outputImage ?? origen
    }

    /// Geometría: giros de 90°, espejo y enderezado del horizonte. Se aplica
    /// antes que cualquier ajuste de color. Al enderezar, la imagen se amplía
    /// lo justo para que no asomen los bordes vacíos y se recorta al marco.
    func aplicarGeometria(a origen: CIImage,
                          parametros p: ParametrosEdicion) -> CIImage {
        var imagen = origen

        if p.volteadoH {
            imagen = imagen.oriented(.upMirrored)
        }
        switch ((p.rotacion % 4) + 4) % 4 {
        case 1: imagen = imagen.oriented(.right)
        case 2: imagen = imagen.oriented(.down)
        case 3: imagen = imagen.oriented(.left)
        default: break
        }

        if p.enderezar != 0 {
            let marco = imagen.extent
            let angulo = p.enderezar * .pi / 180
            // Escala mínima para que el marco original quede cubierto
            // tras el giro (así no aparecen esquinas vacías).
            let seno = abs(sin(angulo)), coseno = abs(cos(angulo))
            let escala = max(coseno + seno * marco.height / marco.width,
                             coseno + seno * marco.width / marco.height)
            let centroX = marco.midX, centroY = marco.midY
            let transformacion = CGAffineTransform(translationX: centroX, y: centroY)
                .rotated(by: CGFloat(-angulo))
                .scaledBy(x: CGFloat(escala), y: CGFloat(escala))
                .translatedBy(x: -centroX, y: -centroY)
            imagen = imagen.transformed(by: transformacion).cropped(to: marco)
        }
        return imagen
    }

    /// Las máscaras de selección disponibles para una foto.
    struct Mascaras {
        var sujeto: CIImage? = nil
        var cielo: CIImage? = nil
        var vegetacion: CIImage? = nil
    }

    /// Aplica la receta completa de tono y color sobre una imagen ya revelada.
    /// `cuboHSL` es la tabla del mezclador generada por ProcesadoColor (se
    /// pasa ya hecha para no recalcularla en cada fotograma).
    /// `mascaras` son las selecciones detectadas (sujeto, cielo, vegetación).
    /// `decodificadoRAW` = true cuando la imagen viene del revelador RAW,
    /// donde exposición, ruido y enfoque YA se aplicaron a nivel de sensor.
    func aplicarAjustes(a origen: CIImage,
                        parametros p: ParametrosEdicion,
                        cuboHSL: Data? = nil,
                        mascaras: Mascaras = Mascaras(),
                        decodificadoRAW: Bool = false) -> CIImage {
        var imagen = aplicarGeometria(a: origen, parametros: p)

        // Exposición: en luz lineal, sumar EV es multiplicar por 2^EV,
        // exactamente como abrir el diafragma. (En RAW ya viene aplicada
        // dentro del revelado, con calidad de sensor.) Al subir, se añade
        // un hombro que protege las altas luces — calibrado contra el motor
        // de referencia: recuperación de 0.65 EV por cada EV positivo.
        if p.exposicion != 0 && !decodificadoRAW {
            let filtro = CIFilter.exposureAdjust()
            filtro.inputImage = imagen
            filtro.ev = Float(p.exposicion)
            imagen = filtro.outputImage ?? imagen

            if p.exposicion > 0 {
                imagen = ajusteBandaTonal(imagen,
                                          ev: -0.65 * p.exposicion,
                                          rampa: [PuntoCurva(x: 0, y: 0),
                                                  PuntoCurva(x: 0.45, y: 0),
                                                  PuntoCurva(x: 0.85, y: 1),
                                                  PuntoCurva(x: 1, y: 1)])
            }
        }

        // ---- Las cuatro bandas tonales: altas luces, sombras, blancos y
        // negros. Todas con el MISMO mecanismo profesional: una máscara de
        // luminosidad con caída progresiva limita el efecto a su banda, y
        // dentro de ella se aplica exposición real (pasos EV). Subir +20 y
        // bajar -20 son movimientos espejo exactos: simetría garantizada.
        //   · Altas luces: banda alta ancha, se desvanece hacia los medios.
        //   · Sombras: banda baja ancha, se desvanece hacia los medios.
        //   · Blancos: solo el extremo superior (el punto blanco).
        //   · Negros: solo el extremo inferior (el punto negro).
        // (Fuerzas y rampas CALIBRADAS contra el motor de referencia sobre
        // exportaciones reales: mismas magnitudes al mover el mismo control.)
        if p.altasLuces != 0 {
            imagen = ajusteBandaTonal(imagen,
                                      ev: p.altasLuces / 100.0 * 0.6,
                                      rampa: [PuntoCurva(x: 0, y: 0),
                                              PuntoCurva(x: 0.45, y: 0),
                                              PuntoCurva(x: 0.85, y: 1),
                                              PuntoCurva(x: 1, y: 1)])
        }
        if p.sombras != 0 {
            imagen = ajusteBandaTonal(imagen,
                                      ev: p.sombras / 100.0 * 2.7,
                                      rampa: [PuntoCurva(x: 0, y: 1),
                                              PuntoCurva(x: 0.15, y: 1),
                                              PuntoCurva(x: 0.55, y: 0),
                                              PuntoCurva(x: 1, y: 0)])
        }
        if p.blancos != 0 {
            imagen = ajusteBandaTonal(imagen,
                                      ev: p.blancos / 100.0 * 0.3,
                                      rampa: [PuntoCurva(x: 0, y: 0),
                                              PuntoCurva(x: 0.55, y: 0),
                                              PuntoCurva(x: 0.9, y: 1),
                                              PuntoCurva(x: 1, y: 1)])
        }
        if p.negros != 0 {
            imagen = ajusteBandaTonal(imagen,
                                      ev: p.negros / 100.0 * 2.8,
                                      rampa: [PuntoCurva(x: 0, y: 1),
                                              PuntoCurva(x: 0.04, y: 1),
                                              PuntoCurva(x: 0.4, y: 0),
                                              PuntoCurva(x: 1, y: 0)])
        }

        // Contraste: curva S de verdad, con pivote en el gris medio y
        // hombros suaves — el contraste "fotográfico", no el genérico.
        if p.contraste != 0 {
            let filtro = CIFilter.colorCurves()
            filtro.inputImage = imagen
            filtro.curvesData = ProcesadoColor.datosCurvaUnica(
                ProcesadoColor.curvaContraste(p.contraste))
            filtro.curvesDomain = CIVector(x: 0, y: 1)
            filtro.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
            imagen = filtro.outputImage ?? imagen
        }

        // Saturación global (factor 0.95 calibrado contra referencia).
        if p.saturacion != 0 {
            let filtro = CIFilter.colorControls()
            filtro.inputImage = imagen
            filtro.saturation = Float(1.0 + p.saturacion / 100.0 * 0.95)
            filtro.brightness = 0
            filtro.contrast = 1
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

        // Curva de tonos (general + por canal), muestreada a 256 pasos.
        // Se evalúa en sRGB con gamma, que es donde la curva resulta natural
        // al ojo; el filtro convierte ida y vuelta desde el espacio lineal.
        if !p.curvaEsNeutra {
            let filtro = CIFilter.colorCurves()
            filtro.inputImage = imagen
            filtro.curvesData = ProcesadoColor.datosCurvas(
                luma: p.curvaLuma, r: p.curvaR, v: p.curvaV, a: p.curvaA)
            filtro.curvesDomain = CIVector(x: 0, y: 1)
            filtro.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
            imagen = filtro.outputImage ?? imagen
        }

        // Tabla de color de look (LUT): la matemática exacta de un estilo
        // calibrado fuera de la app, aplicada en una sola pasada.
        if let nombreLUT = p.lutNombre, let datosLUT = cargarLUT(nombreLUT) {
            let filtro = CIFilter.colorCubeWithColorSpace()
            filtro.inputImage = imagen
            filtro.cubeData = datosLUT
            filtro.cubeDimension = 33
            filtro.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
            imagen = filtro.outputImage ?? imagen
        }

        // Mezclador HSL: el cubo de color con los 8 rangos, en una pasada.
        if let cuboHSL, !p.hslEsNeutro {
            let filtro = CIFilter.colorCubeWithColorSpace()
            filtro.inputImage = imagen
            filtro.cubeData = cuboHSL
            filtro.cubeDimension = 33
            filtro.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
            imagen = filtro.outputImage ?? imagen
        }

        // Textura: realce fino (radio pequeño), como acentuar el grano fino.
        if p.textura != 0 {
            let filtro = CIFilter.unsharpMask()
            filtro.inputImage = imagen
            filtro.radius = 8
            filtro.intensity = Float(p.textura / 100.0 * 0.8)
            imagen = filtro.outputImage ?? imagen
        }

        // Claridad: contraste local (radio grande), el "punch" de los medios.
        if p.claridad != 0 {
            let filtro = CIFilter.unsharpMask()
            filtro.inputImage = imagen
            filtro.radius = 60
            filtro.intensity = Float(p.claridad / 100.0 * 0.5)
            imagen = filtro.outputImage ?? imagen
        }

        // ---- Selecciones: cada zona con su propia luz y saturación ----
        // La zona ajustada y el resto se funden con la máscara detectada.
        func ajustar(_ base: CIImage, luz: Double, saturacion: Double) -> CIImage {
            var resultado = base
            if luz != 0 {
                let filtro = CIFilter.exposureAdjust()
                filtro.inputImage = resultado
                filtro.ev = Float(luz / 100.0)
                resultado = filtro.outputImage ?? resultado
            }
            if saturacion != 0 {
                let filtro = CIFilter.colorControls()
                filtro.inputImage = resultado
                filtro.saturation = Float(1.0 + saturacion / 100.0)
                filtro.brightness = 0
                filtro.contrast = 1
                resultado = filtro.outputImage ?? resultado
            }
            return resultado
        }

        func fundir(zona: CIImage, resto: CIImage, mascara: CIImage) -> CIImage {
            let filtro = CIFilter.blendWithMask()
            filtro.inputImage = zona
            filtro.backgroundImage = resto
            filtro.maskImage = mascara
            return filtro.outputImage ?? resto
        }

        if let sujeto = mascaras.sujeto,
           p.realceSujeto != 0 || p.realceFondo != 0
            || p.saturacionSujeto != 0 || p.saturacionFondo != 0 {
            let mascara = aplicarGeometria(a: sujeto, parametros: p)
            let zonaSujeto = ajustar(imagen, luz: p.realceSujeto,
                                     saturacion: p.saturacionSujeto)
            let zonaFondo = ajustar(imagen, luz: p.realceFondo,
                                    saturacion: p.saturacionFondo)
            imagen = fundir(zona: zonaSujeto, resto: zonaFondo, mascara: mascara)
        }

        if let cielo = mascaras.cielo, p.luzCielo != 0 || p.saturacionCielo != 0 {
            let mascara = aplicarGeometria(a: cielo, parametros: p)
            let zona = ajustar(imagen, luz: p.luzCielo,
                               saturacion: p.saturacionCielo)
            imagen = fundir(zona: zona, resto: imagen, mascara: mascara)
        }

        if let verdes = mascaras.vegetacion, p.luzVerdes != 0 || p.saturacionVerdes != 0 {
            let mascara = aplicarGeometria(a: verdes, parametros: p)
            let zona = ajustar(imagen, luz: p.luzVerdes,
                               saturacion: p.saturacionVerdes)
            imagen = fundir(zona: zona, resto: imagen, mascara: mascara)
        }

        // Reducción de ruido, antes del enfoque para no afilar el ruido.
        // (En RAW ya se hizo dentro del revelado, sobre los datos del sensor.)
        if (p.reduccionRuido > 0 || p.reduccionRuidoColor > 0) && !decodificadoRAW {
            let filtro = CIFilter.noiseReduction()
            filtro.inputImage = imagen
            filtro.noiseLevel = Float(p.reduccionRuido / 100.0 * 0.1)
            filtro.sharpness = Float(1.0 - p.reduccionRuidoColor / 100.0 * 0.6)
            imagen = filtro.outputImage ?? imagen
        }

        // Enfoque de luminancia (no toca el color, solo el detalle).
        // (En RAW ya se hizo dentro del revelado.)
        if p.enfoque > 0 && !decodificadoRAW {
            let filtro = CIFilter.sharpenLuminance()
            filtro.inputImage = imagen
            filtro.sharpness = Float(p.enfoque / 100.0 * 1.2)
            imagen = filtro.outputImage ?? imagen
        }

        // =====================================================================
        // BLOQUE DE EFECTOS EN DOMINIO sRGB. Los efectos de aquí abajo
        // (viraje, neblina, viñeta, halación, grano) están calibrados en
        // valores perceptuales (con gamma), no en luz lineal: ejecutarlos en
        // lineal los exagera brutalmente (un grano suave se vuelve nevada,
        // un tinte leve se vuelve tintazo). Se convierte UNA vez a sRGB, se
        // hacen todos, y se vuelve a lineal al final del bloque.
        // =====================================================================
        let hayEfectosGamma = p.virajeLuces != 0 || p.virajeSombras != 0
            || p.neblina > 0 || p.vineta != 0 || p.halacion > 0 || p.grano > 0
        if hayEfectosGamma {
            imagen = imagen.applyingFilter("CILinearToSRGBToneCurve")
        }

        // Viraje partido: teñir las luces y las sombras por separado, como
        // los virajes químicos de laboratorio. Positivo = cálido (ámbar),
        // negativo = frío (azulado). Usa las mismas máscaras tonales suaves
        // que las bandas de luz.
        if p.virajeLuces != 0 {
            imagen = aplicarViraje(imagen, cantidad: p.virajeLuces,
                                   rampa: [PuntoCurva(x: 0, y: 0),
                                           PuntoCurva(x: 0.45, y: 0),
                                           PuntoCurva(x: 0.95, y: 1),
                                           PuntoCurva(x: 1, y: 1)])
        }
        if p.virajeSombras != 0 {
            imagen = aplicarViraje(imagen, cantidad: p.virajeSombras,
                                   rampa: [PuntoCurva(x: 0, y: 1),
                                           PuntoCurva(x: 0.12, y: 1),
                                           PuntoCurva(x: 0.55, y: 0),
                                           PuntoCurva(x: 1, y: 0)])
        }

        // Quitar neblina: contraste local de radio muy grande, punto negro
        // ligeramente abajo (el velo atmosférico levanta los negros) y una
        // pizca de intensidad para devolver el color que la bruma lava.
        if p.neblina > 0 {
            let cantidad = CGFloat(p.neblina / 100.0)

            let local = CIFilter.unsharpMask()
            local.inputImage = imagen
            local.radius = 140
            local.intensity = Float(cantidad * 0.7)
            imagen = local.outputImage ?? imagen

            let velo = CIFilter.colorMatrix()
            velo.inputImage = imagen
            let ganancia = 1 + 0.08 * cantidad
            velo.rVector = CIVector(x: ganancia, y: 0, z: 0, w: 0)
            velo.gVector = CIVector(x: 0, y: ganancia, z: 0, w: 0)
            velo.bVector = CIVector(x: 0, y: 0, z: ganancia, w: 0)
            velo.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            velo.biasVector = CIVector(x: -0.035 * cantidad,
                                       y: -0.035 * cantidad,
                                       z: -0.035 * cantidad, w: 0)
            imagen = velo.outputImage ?? imagen

            let clamp = CIFilter.colorClamp()
            clamp.inputImage = imagen
            clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
            clamp.maxComponents = CIVector(x: 65504, y: 65504, z: 65504, w: 65504)
            imagen = clamp.outputImage ?? imagen

            let color = CIFilter.vibrance()
            color.inputImage = imagen
            color.amount = Float(cantidad * 0.15)
            imagen = color.outputImage ?? imagen
        }

        // Viñeta: enmarca el resultado ya revelado.
        if p.vineta != 0 {
            let filtro = CIFilter.vignette()
            filtro.inputImage = imagen
            filtro.intensity = Float(p.vineta / 100.0)
            filtro.radius = 2
            imagen = filtro.outputImage ?? imagen
        }

        // Halación: las luces "sangran" un resplandor ámbar difuso, como en
        // la película antigua cuando la luz rebotaba en el soporte. Se aísla
        // el brillo, se difumina en proporción al tamaño de la imagen, se
        // tiñe de ámbar y se SUMA sobre la foto.
        if p.halacion > 0 {
            let intensidad = CGFloat(p.halacion / 100.0) * 0.30

            // Máscara de brillos altos.
            let luma = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
            let gris = CIFilter.colorMatrix()
            gris.inputImage = imagen
            gris.rVector = luma; gris.gVector = luma; gris.bVector = luma
            gris.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            let rampa = CIFilter.colorCurves()
            rampa.inputImage = gris.outputImage
            rampa.curvesData = ProcesadoColor.datosCurvaUnica(
                [PuntoCurva(x: 0, y: 0), PuntoCurva(x: 0.7, y: 0),
                 PuntoCurva(x: 0.96, y: 1), PuntoCurva(x: 1, y: 1)])
            rampa.curvesDomain = CIVector(x: 0, y: 1)
            rampa.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

            if let mascaraBrillo = rampa.outputImage {
                // Solo los brillos, teñidos de ámbar y atenuados.
                let brillos = CIFilter.multiplyCompositing()
                brillos.inputImage = mascaraBrillo
                brillos.backgroundImage = imagen
                let tinte = CIFilter.colorMatrix()
                tinte.inputImage = brillos.outputImage
                tinte.rVector = CIVector(x: 1.0 * intensidad, y: 0, z: 0, w: 0)
                tinte.gVector = CIVector(x: 0, y: 0.86 * intensidad, z: 0, w: 0)
                tinte.bVector = CIVector(x: 0, y: 0, z: 0.62 * intensidad, w: 0)
                tinte.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)

                // Difuminar en proporción al tamaño y sumar.
                if let aislado = tinte.outputImage {
                    let radio = max(6.0, imagen.extent.width / 90.0)
                    let resplandor = aislado
                        .clampedToExtent()
                        .applyingGaussianBlur(sigma: radio)
                        .cropped(to: imagen.extent)
                    let suma = CIFilter.additionCompositing()
                    suma.inputImage = resplandor
                    suma.backgroundImage = imagen
                    imagen = suma.outputImage ?? imagen
                }
            }
        }

        // Grano de película, lo último de todo: ruido monocromo estable
        // (mismo patrón en cada render) fundido en luz suave.
        // La amplitud sigue una curva de potencia para que el deslizador
        // tenga gradación real: a 10 se insinúa, a 50 está presente, a 100
        // es marcado — nada de "todo o nada".
        if p.grano > 0 {
            let intensidad = CGFloat(pow(p.grano / 100.0, 0.75)) * 0.10
            if let ruidoBruto = CIFilter.randomGenerator().outputImage {
                let luma = CIVector(x: 1.0 / 3, y: 1.0 / 3, z: 1.0 / 3, w: 0)
                let gris = CIFilter.colorMatrix()
                // El tamaño del grano escala con la imagen: mismo aspecto en
                // la previsualización y en la exportación a resolución completa.
                let escalaGrano = max(1.2, imagen.extent.width / 2200)
                gris.inputImage = ruidoBruto.transformed(by: .init(scaleX: escalaGrano,
                                                                   y: escalaGrano))
                gris.rVector = CIVector(x: luma.x * intensidad, y: luma.y * intensidad, z: luma.z * intensidad, w: 0)
                gris.gVector = gris.rVector
                gris.bVector = gris.rVector
                gris.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
                // Centrado en el gris medio: en luz suave, 0.5 = sin cambio.
                let centro = 0.5 - intensidad / 2
                gris.biasVector = CIVector(x: centro, y: centro, z: centro, w: 0)

                if let granoListo = gris.outputImage?.cropped(to: imagen.extent) {
                    let fusion = CIFilter.softLightBlendMode()
                    fusion.inputImage = granoListo
                    fusion.backgroundImage = imagen
                    imagen = fusion.outputImage ?? imagen
                }
            }
        }

        // Cierre del bloque de efectos: de vuelta a luz lineal (§5.2).
        if hayEfectosGamma {
            imagen = imagen.applyingFilter("CISRGBToneCurveToLinear")
        }

        return imagen
    }

    // =========================================================================
    // Detección de sujeto (IA en el dispositivo, Vision de iOS 17).
    // Devuelve la máscara del sujeto principal (blanco = sujeto) del mismo
    // tamaño que la imagen, o nil si no se detecta ninguno. Todo ocurre en
    // el motor neuronal del iPhone: nada sale del dispositivo.
    // =========================================================================
    func mascaraSujeto(de imagen: CIImage) -> CIImage? {
        let peticion = VNGenerateForegroundInstanceMaskRequest()
        let manejador = VNImageRequestHandler(ciImage: imagen, options: [:])
        do {
            try manejador.perform([peticion])
        } catch {
            return nil
        }
        guard let resultado = peticion.results?.first,
              !resultado.allInstances.isEmpty,
              let bufer = try? resultado.generateScaledMaskForImage(
                forInstances: resultado.allInstances, from: manejador)
        else { return nil }
        return CIImage(cvPixelBuffer: bufer)
    }

    /// Percentiles de luminosidad para el Auto: el fotómetro matricial de la
    /// app, con los dos extremos (1% y 99%) para vigilar recortes.
    struct EstadisticasTonales {
        let p01: Double, p05: Double, p50: Double, p95: Double, p99: Double
    }

    func estadisticasTonales(de imagen: CIImage) -> EstadisticasTonales? {
        guard let h = calcularHistograma(de: imagen) else { return nil }
        let bins = h.r.count
        let luma = (0..<bins).map { Double(h.r[$0] + h.v[$0] + h.a[$0]) / 3 }
        let total = luma.reduce(0, +)
        guard total > 0 else { return nil }

        func percentil(_ objetivo: Double) -> Double {
            var acumulado = 0.0
            for (i, valor) in luma.enumerated() {
                acumulado += valor
                if acumulado / total >= objetivo {
                    return Double(i) / Double(bins - 1)
                }
            }
            return 1
        }
        return EstadisticasTonales(p01: percentil(0.01), p05: percentil(0.05),
                                   p50: percentil(0.5), p95: percentil(0.95),
                                   p99: percentil(0.99))
    }

    // =========================================================================
    // Máscaras por análisis de color (cielo y vegetación). Se calculan a baja
    // resolución en CPU con criterios fotográficos (dominancia de canal más
    // posición en el encuadre para el cielo), se suavizan y se escalan.
    // =========================================================================
    enum ZonaHeuristica { case cielo, vegetacion }

    func mascaraHeuristica(de imagen: CIImage, zona: ZonaHeuristica) -> CIImage? {
        let extension_ = imagen.extent
        guard extension_.width > 0, extension_.height > 0 else { return nil }

        // Analizar a baja resolución: sobra para una máscara suave.
        let ladoAnalisis = 240.0
        let escala = ladoAnalisis / max(extension_.width, extension_.height)
        let ancho = max(8, Int(extension_.width * escala))
        let alto = max(8, Int(extension_.height * escala))

        var pixeles = [UInt8](repeating: 0, count: ancho * alto * 4)
        let reducida = imagen.transformed(by: .init(scaleX: escala, y: escala))
        contexto.render(reducida, toBitmap: &pixeles, rowBytes: ancho * 4,
                        bounds: CGRect(x: 0, y: 0, width: ancho, height: alto),
                        format: .RGBA8, colorSpace: espacioSalidaPantalla)

        var mascara = [UInt8](repeating: 0, count: ancho * alto)
        var cubiertos = 0
        for y in 0..<alto {
            // toBitmap entrega la fila 0 arriba; la imagen cuenta desde abajo.
            let alturaNormalizada = 1.0 - Double(y) / Double(alto - 1)
            for x in 0..<ancho {
                let i = (y * ancho + x) * 4
                let r = Double(pixeles[i]) / 255
                let g = Double(pixeles[i + 1]) / 255
                let b = Double(pixeles[i + 2]) / 255
                let luminancia = 0.2126 * r + 0.7152 * g + 0.0722 * b

                var peso = 0.0
                switch zona {
                case .cielo:
                    // Azul dominante y luminoso, con más confianza cuanto
                    // más arriba del encuadre.
                    let dominanciaAzul = b - max(r, g * 0.95)
                    if dominanciaAzul > 0.02 && luminancia > 0.25 {
                        peso = min(1, dominanciaAzul * 8)
                            * (0.35 + 0.65 * alturaNormalizada)
                    }
                    // Cielo blanco/nublado: muy luminoso, casi neutro, arriba.
                    let neutro = abs(r - g) < 0.05 && abs(g - b) < 0.06
                    if peso < 0.2 && neutro && luminancia > 0.82
                        && alturaNormalizada > 0.55 {
                        peso = 0.7
                    }
                case .vegetacion:
                    // Verde dominante sobre rojo y azul.
                    let dominanciaVerde = g - max(r * 1.02, b * 1.05)
                    if dominanciaVerde > 0.02 {
                        peso = min(1, dominanciaVerde * 9)
                    }
                }
                if peso > 0.15 { cubiertos += 1 }
                mascara[y * ancho + x] = UInt8(min(255, max(0, peso * 255)))
            }
        }

        // Si la zona apenas existe en la foto, mejor no ofrecer la selección.
        guard Double(cubiertos) / Double(ancho * alto) > 0.02 else { return nil }

        // Gris de un canal -> imagen; suavizar; escalar al tamaño real.
        var rgba = [UInt8](repeating: 255, count: ancho * alto * 4)
        for i in 0..<(ancho * alto) {
            rgba[i * 4] = mascara[i]
            rgba[i * 4 + 1] = mascara[i]
            rgba[i * 4 + 2] = mascara[i]
        }
        let datos = Data(rgba)
        guard var imagenMascara = CIImage(
            bitmapData: datos, bytesPerRow: ancho * 4,
            size: CGSize(width: ancho, height: alto),
            format: .RGBA8, colorSpace: nil) as CIImage? else { return nil }

        imagenMascara = imagenMascara
            .applyingGaussianBlur(sigma: 2.5)
            .cropped(to: CGRect(x: 0, y: 0, width: ancho, height: alto))
            .transformed(by: .init(scaleX: extension_.width / CGFloat(ancho),
                                   y: extension_.height / CGFloat(alto)))
            .transformed(by: .init(translationX: extension_.origin.x,
                                   y: extension_.origin.y))
        return imagenMascara
    }

    /// Luminosidad media de la imagen (0...1, en valores de pantalla), para
    /// el botón Auto: es el fotómetro de la app.
    func luminanciaMedia(de imagen: CIImage) -> Double? {
        let filtro = CIFilter.areaAverage()
        filtro.inputImage = imagen
        filtro.extent = imagen.extent
        guard let promedio = filtro.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        contexto.render(promedio, toBitmap: &pixel, rowBytes: 4,
                        bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                        format: .RGBA8, colorSpace: espacioSalidaPantalla)
        let r = Double(pixel[0]) / 255, g = Double(pixel[1]) / 255, b = Double(pixel[2]) / 255
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    // =========================================================================
    // Histograma en vivo: cuenta la distribución de tonos del resultado y
    // devuelve 64 alturas normalizadas por canal (R, V, A), listas para
    // dibujarse. Se calcula sobre la imagen de previsualización.
    // =========================================================================
    func calcularHistograma(de imagen: CIImage) -> (r: [Float], v: [Float], a: [Float])? {
        let bins = 64
        let filtro = CIFilter.areaHistogram()
        filtro.inputImage = imagen
        filtro.extent = imagen.extent
        filtro.count = bins
        filtro.scale = 1
        guard let salida = filtro.outputImage else { return nil }

        var pixeles = [Float](repeating: 0, count: bins * 4)
        pixeles.withUnsafeMutableBytes { puntero in
            contexto.render(salida,
                            toBitmap: puntero.baseAddress!,
                            rowBytes: bins * 4 * MemoryLayout<Float>.size,
                            bounds: CGRect(x: 0, y: 0, width: bins, height: 1),
                            format: .RGBAf,
                            colorSpace: nil)
        }

        var r = [Float](repeating: 0, count: bins)
        var v = [Float](repeating: 0, count: bins)
        var a = [Float](repeating: 0, count: bins)
        for i in 0..<bins {
            r[i] = pixeles[i * 4]
            v[i] = pixeles[i * 4 + 1]
            a[i] = pixeles[i * 4 + 2]
        }
        // Normalizar al pico (ignorando los extremos, que suelen dispararse).
        var pico: Float = 0.0001
        for i in 1..<(bins - 1) {
            pico = max(pico, r[i], v[i], a[i])
        }
        func normalizar(_ c: [Float]) -> [Float] { c.map { min(1, $0 / pico) } }
        return (normalizar(r), normalizar(v), normalizar(a))
    }
}
