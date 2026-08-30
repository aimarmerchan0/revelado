// =============================================================================
// ParametrosEdicion.swift — la "receta de revelado" de una foto
//
// Regla §5.5: editar no cambia píxeles, cambia NÚMEROS. Esta struct son esos
// números. Se guarda como JSON en la ficha de la foto (SwiftData) y revelar
// es siempre una función pura: (original, parámetros) -> imagen.
// Deshacer = volver a números anteriores. Neutro = original intacto.
// =============================================================================

import Foundation

struct ParametrosEdicion: Codable, Equatable {

    // --- Básicos de tono ---
    /// Exposición en pasos EV (-5...+5). 0 = como salió de cámara.
    var exposicion: Double = 0
    /// Contraste (-100...+100).
    var contraste: Double = 0
    /// Altas luces (-100...+100). Negativo recupera; positivo realza.
    var altasLuces: Double = 0
    /// Sombras (-100...+100). Positivo abre sombras; negativo las cierra.
    var sombras: Double = 0
    /// Blancos (-100...+100): el punto blanco, el extremo alto de la escala.
    var blancos: Double = 0
    /// Negros (-100...+100): el punto negro. Positivo levanta, negativo empasta.
    var negros: Double = 0

    // --- Balance de blancos ---
    /// Temperatura (-100...+100). Positivo = más cálido (~±2000 K).
    var temperatura: Double = 0
    /// Matiz (-100...+100). Positivo = magenta, negativo = verde.
    var matiz: Double = 0

    // --- Color ---
    /// Intensidad (vibrance): satura con cuidado, protegiendo lo ya saturado.
    var intensidad: Double = 0
    /// Saturación global (-100...+100).
    var saturacion: Double = 0

    /// La receta sin tocar: todo a cero.
    static let neutros = ParametrosEdicion()

    var esNeutro: Bool { self == ParametrosEdicion.neutros }
}
