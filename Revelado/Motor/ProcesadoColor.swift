// =============================================================================
// ProcesadoColor.swift — matemática de color pura (sin GPU, sin estado)
//
// Dos herramientas viven aquí:
//
//  1. La CURVA DE TONOS: a partir de los puntos que el usuario coloca se
//     interpola una curva suave y se muestrea en 256 pasos, que es lo que
//     el filtro CIColorCurves necesita.
//
//  2. El MEZCLADOR HSL: se genera un "cubo de color" 3D (una tabla que dice
//     para cada color de entrada qué color sale). Es la técnica clásica de
//     los editores profesionales: permite ajustar tono/saturación/luminancia
//     por rangos de color sin escribir un kernel de GPU a mano, y el filtro
//     CIColorCube la aplica en una sola pasada.
// =============================================================================

import Foundation

enum ProcesadoColor {

    // =========================================================================
    // Curva de tonos
    // =========================================================================

    /// Interpola los puntos con Catmull-Rom (curva suave que pasa por todos
    /// los puntos, como la de cualquier editor fotográfico) y devuelve
    /// `muestras` valores 0...1.
    static func muestrearCurva(_ puntos: [PuntoCurva], muestras: Int = 256) -> [Float] {
        let ordenados = puntos.sorted { $0.x < $1.x }
        guard ordenados.count >= 2 else {
            return (0..<muestras).map { Float($0) / Float(muestras - 1) }
        }

        func punto(_ i: Int) -> PuntoCurva {
            ordenados[min(max(i, 0), ordenados.count - 1)]
        }

        var resultado = [Float](repeating: 0, count: muestras)
        for m in 0..<muestras {
            let x = Double(m) / Double(muestras - 1)

            // Fuera del primer/último punto la curva continúa plana.
            if x <= ordenados.first!.x {
                resultado[m] = Float(ordenados.first!.y); continue
            }
            if x >= ordenados.last!.x {
                resultado[m] = Float(ordenados.last!.y); continue
            }

            // Buscar el tramo que contiene x.
            var i = 0
            while i < ordenados.count - 2 && ordenados[i + 1].x < x { i += 1 }

            let p0 = punto(i - 1), p1 = punto(i), p2 = punto(i + 1), p3 = punto(i + 2)
            let ancho = p2.x - p1.x
            let t = ancho > 0 ? (x - p1.x) / ancho : 0
            let t2 = t * t, t3 = t2 * t

            // Catmull-Rom estándar.
            let y = 0.5 * ((2 * p1.y)
                + (-p0.y + p2.y) * t
                + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2
                + (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3)

            resultado[m] = Float(min(1, max(0, y)))
        }
        return resultado
    }

    /// Combina la curva de luminosidad con las de cada canal y devuelve los
    /// datos RGB entrelazados (256 × 3 Float) que espera CIColorCurves.
    /// Primero actúa la curva general y sobre su resultado la del canal,
    /// igual que en los editores clásicos.
    static func datosCurvas(luma: [PuntoCurva], r: [PuntoCurva],
                            v: [PuntoCurva], a: [PuntoCurva]) -> Data {
        let n = 256
        let tablaLuma = muestrearCurva(luma, muestras: n)
        let tablaR = muestrearCurva(r, muestras: n)
        let tablaV = muestrearCurva(v, muestras: n)
        let tablaA = muestrearCurva(a, muestras: n)

        func encadenar(_ canal: [Float], _ x: Int) -> Float {
            let tras = tablaLuma[x]
            let indice = min(n - 1, max(0, Int((tras * Float(n - 1)).rounded())))
            return canal[indice]
        }

        var datos = [Float](repeating: 0, count: n * 3)
        for x in 0..<n {
            datos[x * 3 + 0] = encadenar(tablaR, x)
            datos[x * 3 + 1] = encadenar(tablaV, x)
            datos[x * 3 + 2] = encadenar(tablaA, x)
        }
        return datos.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Muestrea una única curva y la replica en los tres canales, en el
    /// formato de CIColorCurves. Se usa para la curva S del contraste.
    static func datosCurvaUnica(_ puntos: [PuntoCurva]) -> Data {
        let n = 256
        let tabla = muestrearCurva(puntos, muestras: n)
        var datos = [Float](repeating: 0, count: n * 3)
        for x in 0..<n {
            datos[x * 3 + 0] = tabla[x]
            datos[x * 3 + 1] = tabla[x]
            datos[x * 3 + 2] = tabla[x]
        }
        return datos.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// La curva S del contraste: pivote en el gris medio, hombros suaves.
    /// Factor con anclas del barrido de calibración: la referencia aprieta
    /// algo más al bajar contraste (0.11) que al subirlo (0.08-0.10).
    static func curvaContraste(_ contraste: Double) -> [PuntoCurva] {
        let anclas: [(Double, Double)] = [(-100, 0.11), (-50, 0.11),
                                          (50, 0.08), (100, 0.10)]
        var factor = anclas.last!.1
        if contraste <= anclas.first!.0 {
            factor = anclas.first!.1
        } else if contraste >= anclas.last!.0 {
            factor = anclas.last!.1
        } else {
            for i in 0..<(anclas.count - 1) {
                let a = anclas[i], b = anclas[i + 1]
                if contraste >= a.0 && contraste <= b.0 {
                    let t = (contraste - a.0) / (b.0 - a.0)
                    factor = a.1 + (b.1 - a.1) * t
                    break
                }
            }
        }
        let c = contraste / 100.0 * factor
        return [PuntoCurva(x: 0, y: 0),
                PuntoCurva(x: 0.25, y: 0.25 - c),
                PuntoCurva(x: 0.5, y: 0.5),
                PuntoCurva(x: 0.75, y: 0.75 + c),
                PuntoCurva(x: 1, y: 1)]
    }

    // =========================================================================
    // Mezclador HSL → cubo de color
    // =========================================================================

    /// Centros de los 8 rangos en la rueda de tono (0...360):
    /// rojo, naranja, amarillo, verde, aqua, azul, púrpura, magenta.
    static let centrosTono: [Double] = [0, 30, 60, 120, 180, 240, 280, 320]

    /// Peso de pertenencia de un tono a cada rango (campana triangular con
    /// solape, para transiciones suaves entre rangos vecinos).
    static func pesos(paraTono h: Double) -> [Double] {
        var resultado = [Double](repeating: 0, count: 8)
        for (i, centro) in centrosTono.enumerated() {
            var distancia = abs(h - centro)
            if distancia > 180 { distancia = 360 - distancia }
            let anchura = 40.0 // medio ancho de la campana
            if distancia < anchura {
                resultado[i] = 1 - distancia / anchura
            }
        }
        // Normalizar para que los pesos sumen 1 donde haya solape.
        let suma = resultado.reduce(0, +)
        if suma > 0 { resultado = resultado.map { $0 / suma } }
        return resultado
    }

    /// Genera el cubo de color (dimensión³ × RGBA Float) aplicando los
    /// ajustes HSL de los 8 rangos. Los valores del cubo van en sRGB con
    /// gamma (el filtro se encarga de convertir desde el espacio de trabajo).
    static func generarCuboHSL(_ ajustes: [AjusteHSL], dimension: Int = 33) -> Data {
        var datos = [Float]()
        datos.reserveCapacity(dimension * dimension * dimension * 4)

        for b in 0..<dimension {
            for g in 0..<dimension {
                for r in 0..<dimension {
                    let rf = Double(r) / Double(dimension - 1)
                    let gf = Double(g) / Double(dimension - 1)
                    let bf = Double(b) / Double(dimension - 1)

                    var (h, s, v) = rgbAHsv(rf, gf, bf)

                    if s > 0.001 { // los grises no pertenecen a ningún rango
                        let w = pesos(paraTono: h)
                        var dTono = 0.0, dSat = 0.0, dLum = 0.0
                        for i in 0..<8 where !ajustes[i].esNeutro {
                            dTono += w[i] * ajustes[i].tono
                            dSat += w[i] * ajustes[i].saturacion
                            dLum += w[i] * ajustes[i].luminancia
                        }
                        // La fuerza del efecto acompaña a la saturación del
                        // píxel: un color casi gris apenas se mueve.
                        let fuerza = min(1, s * 3)
                        h += dTono * 0.3 * fuerza           // ±30° máximo
                        if h < 0 { h += 360 }; if h >= 360 { h -= 360 }
                        s *= 1 + dSat / 100 * fuerza
                        v *= 1 + dLum / 200 * fuerza        // ±50% máximo
                        s = min(1, max(0, s))
                        v = min(1, max(0, v))
                    }

                    let (nr, ng, nb) = hsvARgb(h, s, v)
                    datos.append(Float(nr))
                    datos.append(Float(ng))
                    datos.append(Float(nb))
                    datos.append(1)
                }
            }
        }
        return datos.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Cubo de INTENSIDAD (vibrance) con fórmula propia anclada al barrido:
    /// satura con más fuerza lo poco saturado y protege lo ya saturado.
    /// s' = s + (v/100)·factor(v)·s·(1-s)·2, con el factor medido por ancla.
    static func generarCuboVibrance(_ cantidad: Double, dimension: Int = 33) -> Data {
        let anclas: [(Double, Double)] = [(-100, 1.35), (-50, 0.90),
                                          (50, 0.50), (100, 0.75)]
        var factor = anclas.last!.1
        if cantidad <= anclas.first!.0 { factor = anclas.first!.1 }
        else if cantidad >= anclas.last!.0 { factor = anclas.last!.1 }
        else {
            for i in 0..<(anclas.count - 1) {
                let a = anclas[i], b = anclas[i + 1]
                if cantidad >= a.0 && cantidad <= b.0 {
                    let t = (cantidad - a.0) / (b.0 - a.0)
                    factor = a.1 + (b.1 - a.1) * t
                    break
                }
            }
        }
        let v = cantidad / 100.0

        var datos = [Float]()
        datos.reserveCapacity(dimension * dimension * dimension * 4)
        for b in 0..<dimension {
            for g in 0..<dimension {
                for r in 0..<dimension {
                    let rf = Double(r) / Double(dimension - 1)
                    let gf = Double(g) / Double(dimension - 1)
                    let bf = Double(b) / Double(dimension - 1)
                    var (h, s, val) = rgbAHsv(rf, gf, bf)
                    let s2 = min(1, max(0, s + v * factor * s * (1 - s) * 2))
                    s = s2
                    let (nr, ng, nb) = hsvARgb(h, s, val)
                    datos.append(Float(nr)); datos.append(Float(ng))
                    datos.append(Float(nb)); datos.append(1)
                }
            }
        }
        return datos.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // --- Conversión RGB <-> HSV clásica ---

    static func rgbAHsv(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let maximo = max(r, g, b), minimo = min(r, g, b)
        let delta = maximo - minimo
        var h = 0.0
        if delta > 0 {
            if maximo == r { h = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
            else if maximo == g { h = 60 * ((b - r) / delta + 2) }
            else { h = 60 * ((r - g) / delta + 4) }
            if h < 0 { h += 360 }
        }
        let s = maximo > 0 ? delta / maximo : 0
        return (h, s, maximo)
    }

    static func hsvARgb(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
        let c = v * s
        let hh = h / 60
        let x = c * (1 - abs(hh.truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let (r, g, b): (Double, Double, Double)
        switch hh {
        case 0..<1: (r, g, b) = (c, x, 0)
        case 1..<2: (r, g, b) = (x, c, 0)
        case 2..<3: (r, g, b) = (0, c, x)
        case 3..<4: (r, g, b) = (0, x, c)
        case 4..<5: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return (r + m, g + m, b + m)
    }
}
