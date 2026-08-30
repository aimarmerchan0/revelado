// =============================================================================
// ParametrosEdicion.swift — la "receta de revelado" de una foto
//
// Regla §5.5: editar no cambia píxeles, cambia NÚMEROS. Esta struct son esos
// números. Se guarda como JSON en la ficha de la foto (SwiftData) y revelar
// es siempre una función pura: (original, parámetros) -> imagen.
//
// La decodificación usa decodeIfPresent con valores por defecto: una receta
// guardada por una versión antigua de la app sigue abriéndose siempre.
// =============================================================================

import Foundation

/// Un punto de la curva de tonos, en coordenadas 0...1 (entrada, salida).
struct PuntoCurva: Codable, Equatable {
    var x: Double
    var y: Double
}

/// Ajuste de un rango de color del mezclador: tono, saturación y luminancia,
/// cada uno -100...+100.
struct AjusteHSL: Codable, Equatable {
    var tono: Double = 0
    var saturacion: Double = 0
    var luminancia: Double = 0
    var esNeutro: Bool { tono == 0 && saturacion == 0 && luminancia == 0 }
}

struct ParametrosEdicion: Codable, Equatable {

    /// La curva identidad: una diagonal que no cambia nada.
    static let curvaIdentidad = [PuntoCurva(x: 0, y: 0), PuntoCurva(x: 1, y: 1)]

    /// Los ocho rangos del mezclador de color, en orden de rueda cromática.
    static let nombresHSL = ["Rojo", "Naranja", "Amarillo", "Verde",
                             "Aqua", "Azul", "Púrpura", "Magenta"]

    // --- Geometría (se aplica antes que todo lo demás) ---
    /// Giros de 90° en sentido horario (0, 1, 2 o 3).
    var rotacion: Int = 0
    /// Volteado horizontal (espejo).
    var volteadoH: Bool = false
    /// Enderezar el horizonte, en grados (-45...+45).
    var enderezar: Double = 0

    // --- Básicos de tono ---
    var exposicion: Double = 0      // pasos EV (-5...+5)
    var contraste: Double = 0
    var altasLuces: Double = 0
    var sombras: Double = 0
    var blancos: Double = 0
    var negros: Double = 0

    // --- Curva de tonos ---
    var curvaLuma: [PuntoCurva] = ParametrosEdicion.curvaIdentidad
    var curvaR: [PuntoCurva] = ParametrosEdicion.curvaIdentidad
    var curvaV: [PuntoCurva] = ParametrosEdicion.curvaIdentidad
    var curvaA: [PuntoCurva] = ParametrosEdicion.curvaIdentidad

    // --- Balance de blancos ---
    var temperatura: Double = 0     // ±100 ≈ ±3500 K
    var matiz: Double = 0
    var puntoNeutroX: Double? = nil
    var puntoNeutroY: Double? = nil
    var neutroR: Double? = nil
    var neutroG: Double? = nil
    var neutroB: Double? = nil

    // --- Color ---
    var intensidad: Double = 0
    var saturacion: Double = 0
    /// Mezclador: 8 rangos (rojo, naranja, amarillo, verde, aqua, azul,
    /// púrpura, magenta), cada uno con tono/saturación/luminancia.
    var hsl: [AjusteHSL] = Array(repeating: AjusteHSL(), count: 8)

    // --- Efectos ---
    var textura: Double = 0
    var claridad: Double = 0
    var vineta: Double = 0          // negativo oscurece bordes, positivo aclara

    // --- Detalle ---
    var enfoque: Double = 0         // 0...100
    var reduccionRuido: Double = 0  // 0...100
    var reduccionRuidoColor: Double = 0

    /// La receta sin tocar.
    static let neutros = ParametrosEdicion()

    var esNeutro: Bool { self == ParametrosEdicion.neutros }

    var curvaEsNeutra: Bool {
        curvaLuma == Self.curvaIdentidad && curvaR == Self.curvaIdentidad
            && curvaV == Self.curvaIdentidad && curvaA == Self.curvaIdentidad
    }

    var hslEsNeutro: Bool { hsl.allSatisfy(\.esNeutro) }

    // =========================================================================
    // Codable a prueba de versiones: cada campo que falte en un JSON antiguo
    // toma su valor neutro en vez de romper la carga.
    // =========================================================================

    init() {}

    private enum Claves: String, CodingKey {
        case rotacion, volteadoH, enderezar
        case exposicion, contraste, altasLuces, sombras, blancos, negros
        case curvaLuma, curvaR, curvaV, curvaA
        case temperatura, matiz, puntoNeutroX, puntoNeutroY, neutroR, neutroG, neutroB
        case intensidad, saturacion, hsl
        case textura, claridad, vineta
        case enfoque, reduccionRuido, reduccionRuidoColor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Claves.self)
        rotacion = try c.decodeIfPresent(Int.self, forKey: .rotacion) ?? 0
        volteadoH = try c.decodeIfPresent(Bool.self, forKey: .volteadoH) ?? false
        enderezar = try c.decodeIfPresent(Double.self, forKey: .enderezar) ?? 0
        exposicion = try c.decodeIfPresent(Double.self, forKey: .exposicion) ?? 0
        contraste = try c.decodeIfPresent(Double.self, forKey: .contraste) ?? 0
        altasLuces = try c.decodeIfPresent(Double.self, forKey: .altasLuces) ?? 0
        sombras = try c.decodeIfPresent(Double.self, forKey: .sombras) ?? 0
        blancos = try c.decodeIfPresent(Double.self, forKey: .blancos) ?? 0
        negros = try c.decodeIfPresent(Double.self, forKey: .negros) ?? 0
        curvaLuma = try c.decodeIfPresent([PuntoCurva].self, forKey: .curvaLuma) ?? Self.curvaIdentidad
        curvaR = try c.decodeIfPresent([PuntoCurva].self, forKey: .curvaR) ?? Self.curvaIdentidad
        curvaV = try c.decodeIfPresent([PuntoCurva].self, forKey: .curvaV) ?? Self.curvaIdentidad
        curvaA = try c.decodeIfPresent([PuntoCurva].self, forKey: .curvaA) ?? Self.curvaIdentidad
        temperatura = try c.decodeIfPresent(Double.self, forKey: .temperatura) ?? 0
        matiz = try c.decodeIfPresent(Double.self, forKey: .matiz) ?? 0
        puntoNeutroX = try c.decodeIfPresent(Double.self, forKey: .puntoNeutroX)
        puntoNeutroY = try c.decodeIfPresent(Double.self, forKey: .puntoNeutroY)
        neutroR = try c.decodeIfPresent(Double.self, forKey: .neutroR)
        neutroG = try c.decodeIfPresent(Double.self, forKey: .neutroG)
        neutroB = try c.decodeIfPresent(Double.self, forKey: .neutroB)
        intensidad = try c.decodeIfPresent(Double.self, forKey: .intensidad) ?? 0
        saturacion = try c.decodeIfPresent(Double.self, forKey: .saturacion) ?? 0
        hsl = try c.decodeIfPresent([AjusteHSL].self, forKey: .hsl)
            ?? Array(repeating: AjusteHSL(), count: 8)
        if hsl.count != 8 { hsl = Array(repeating: AjusteHSL(), count: 8) }
        textura = try c.decodeIfPresent(Double.self, forKey: .textura) ?? 0
        claridad = try c.decodeIfPresent(Double.self, forKey: .claridad) ?? 0
        vineta = try c.decodeIfPresent(Double.self, forKey: .vineta) ?? 0
        enfoque = try c.decodeIfPresent(Double.self, forKey: .enfoque) ?? 0
        reduccionRuido = try c.decodeIfPresent(Double.self, forKey: .reduccionRuido) ?? 0
        reduccionRuidoColor = try c.decodeIfPresent(Double.self, forKey: .reduccionRuidoColor) ?? 0
    }
}
