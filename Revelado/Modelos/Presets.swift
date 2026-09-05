// =============================================================================
// Presets.swift — looks integrados y presets del usuario
//
// Un "look" es una receta parcial: toca tono, color, curva, mezclador y
// efectos, pero nunca la geometría ni las selecciones de cada foto.
// Los looks integrados son recetas propias de la app, pensadas como puntos
// de partida clásicos del revelado. Los presets del usuario se guardan en
// SwiftData con nombre, a partir de la edición actual.
// =============================================================================

import Foundation
import SwiftData

/// Un preset guardado por el usuario. Además de la receta, recuerda el tono
/// medio de la foto donde se creó: así, al aplicarlo sobre una foto más
/// clara u oscura, la exposición se adapta y el ESTILO cae igual.
@Model
final class PresetGuardado {
    @Attribute(.unique) var id: UUID
    var nombre: String
    var fechaCreacion: Date
    var parametrosJSON: Data
    /// Luminosidad mediana (0...1) de la foto de referencia, o nil si no
    /// se pudo medir al guardar.
    var tonoMedioReferencia: Double?

    init(nombre: String, parametros: ParametrosEdicion,
         tonoMedioReferencia: Double? = nil) {
        self.id = UUID()
        self.nombre = nombre
        self.fechaCreacion = Date()
        self.parametrosJSON = (try? JSONEncoder().encode(parametros)) ?? Data()
        self.tonoMedioReferencia = tonoMedioReferencia
    }

    var parametros: ParametrosEdicion? {
        try? JSONDecoder().decode(ParametrosEdicion.self, from: parametrosJSON)
    }
}

/// Un look integrado: nombre y receta.
struct LookIntegrado: Identifiable {
    let nombre: String
    let simbolo: String
    let receta: ParametrosEdicion
    var id: String { nombre }
}

enum Looks {

    /// Construye una receta partiendo de neutro y ajustando campos.
    private static func receta(_ ajustar: (inout ParametrosEdicion) -> Void) -> ParametrosEdicion {
        var p = ParametrosEdicion.neutros
        ajustar(&p)
        return p
    }

    static let integrados: [LookIntegrado] = [
        LookIntegrado(nombre: "Dorado 70", simbolo: "sun.haze.fill", receta: receta { p in
            // El estilo calibrado con Aimar sobre su foto de la costa:
            // baño ámbar, negros mate, verdes hacia ocre, grano presente.
            p.temperatura = 14; p.matiz = 2
            p.contraste = 10; p.blancos = -14; p.sombras = 6
            p.saturacion = -15
            p.curvaLuma = [PuntoCurva(x: 0, y: 0.055),
                           PuntoCurva(x: 0.25, y: 0.26),
                           PuntoCurva(x: 0.75, y: 0.79),
                           PuntoCurva(x: 1, y: 0.955)]
            p.hsl[3].tono = 18; p.hsl[3].saturacion = -25   // verdes → ocre
            p.hsl[2].saturacion = -10                        // amarillos calmados
            p.vineta = -18; p.grano = 30
            // Con las herramientas nuevas, el viraje real del estilo:
            p.virajeLuces = 30; p.virajeSombras = 18
        }),
        LookIntegrado(nombre: "Vivo", simbolo: "sun.max.fill", receta: receta { p in
            p.contraste = 15; p.intensidad = 28; p.saturacion = 5
            p.claridad = 10; p.sombras = 8
        }),
        LookIntegrado(nombre: "Paisaje", simbolo: "mountain.2.fill", receta: receta { p in
            p.altasLuces = -25; p.sombras = 18; p.intensidad = 30
            p.claridad = 18; p.saturacion = 6
            p.hsl[3].saturacion = 12   // verdes
            p.hsl[5].saturacion = 15   // azules
        }),
        LookIntegrado(nombre: "Retrato cálido", simbolo: "person.fill", receta: receta { p in
            p.temperatura = 10; p.sombras = 12; p.altasLuces = -12
            p.intensidad = 12; p.claridad = -8
            p.hsl[1].luminancia = 8    // naranjas: piel más luminosa
        }),
        LookIntegrado(nombre: "Cine", simbolo: "film.fill", receta: receta { p in
            p.temperatura = 6; p.matiz = -4; p.contraste = 14
            p.sombras = 12; p.negros = 8; p.vineta = -18
            p.hsl[5].tono = -10        // azules hacia teal
            p.hsl[1].saturacion = 8    // naranjas presentes
        }),
        LookIntegrado(nombre: "Mate", simbolo: "cloud.fill", receta: receta { p in
            p.contraste = -8; p.negros = 20; p.blancos = -10
            p.saturacion = -12; p.claridad = -5
        }),
        LookIntegrado(nombre: "B/N contraste", simbolo: "circle.lefthalf.filled", receta: receta { p in
            p.saturacion = -100; p.contraste = 25; p.claridad = 15
            p.altasLuces = -15; p.sombras = 10
        }),
        LookIntegrado(nombre: "B/N suave", simbolo: "circle.lefthalf.filled.inverse", receta: receta { p in
            p.saturacion = -100; p.contraste = -5; p.sombras = 18
            p.negros = 12; p.claridad = -5
        }),
    ]
}
