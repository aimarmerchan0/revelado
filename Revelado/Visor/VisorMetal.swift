// =============================================================================
// VisorMetal.swift — la pantalla de enfoque: donde se ve la imagen revelada
//
// ¿Por qué no usar la vista de imagen normal de SwiftUI? Porque esa pasa por
// 8 bits y rompería la regla §5.1 incluso en la previsualización. Este visor
// dibuja directamente con Metal (la GPU) a 16 bits por canal y con salida en
// Display P3, de principio a fin.
//
// De momento el visor solo encaja la imagen entera en pantalla (como ver el
// fotograma completo en la lupa). El zoom y el desplazamiento son el punto 5.
// =============================================================================

import SwiftUI
import MetalKit
import CoreImage

/// Puente entre SwiftUI y la vista Metal (MTKView) que dibuja la imagen.
/// SwiftUI no sabe hablar con Metal directamente; esta estructura traduce.
struct VisorMetal: UIViewRepresentable {

    /// La imagen revelada a mostrar. Si es nil, el visor se queda en negro.
    let imagen: CIImage?
    /// Zoom del visor: 1 = foto encajada entera; >1 = ampliada.
    var escala: CGFloat = 1
    /// Desplazamiento al estar ampliada, en puntos de pantalla.
    var desplazamiento: CGSize = .zero

    func makeCoordinator() -> Dibujante {
        Dibujante()
    }

    /// Se llama UNA vez: monta y configura la vista Metal.
    func makeUIView(context: Context) -> MTKView {
        let vista = MTKView()
        vista.device = MTLCreateSystemDefaultDevice()
        vista.delegate = context.coordinator

        // §5.1 — el lienzo de pantalla también es de 16 bits por canal
        // (half float). Nada de 8 bits, tampoco en la previsualización.
        vista.colorPixelFormat = .rgba16Float

        // §5.3 — la capa de pantalla declara Display P3 como su espacio,
        // para que el sistema interprete bien el color que le entregamos.
        (vista.layer as? CAMetalLayer)?.colorspace =
            MotorRevelado.compartido.espacioSalidaPantalla

        // Core Image necesita permiso para escribir en la textura de pantalla.
        vista.framebufferOnly = false

        // Solo redibujamos cuando cambia algo (no 60 veces por segundo):
        // ahorra batería y es suficiente para un editor de foto fija.
        vista.isPaused = true
        vista.enableSetNeedsDisplay = true

        return vista
    }

    /// Se llama cada vez que SwiftUI detecta que la imagen o el zoom cambian.
    func updateUIView(_ vista: MTKView, context: Context) {
        context.coordinator.imagen = imagen
        context.coordinator.escala = escala
        context.coordinator.desplazamiento = desplazamiento
        vista.setNeedsDisplay()
    }

    // =========================================================================
    // El dibujante: recibe la orden de "redibuja" y ejecuta el render.
    // =========================================================================
    final class Dibujante: NSObject, MTKViewDelegate {

        /// La imagen actual (la "receta" de Core Image, aún sin renderizar).
        var imagen: CIImage?
        /// Zoom y desplazamiento actuales (los fija updateUIView).
        var escala: CGFloat = 1
        var desplazamiento: CGSize = .zero

        /// La cola de órdenes hacia la GPU.
        private lazy var colaComandos: MTLCommandQueue? =
            MTLCreateSystemDefaultDevice()?.makeCommandQueue()

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // El tamaño lo recalculamos en cada draw; nada que hacer aquí.
        }

        func draw(in view: MTKView) {
            guard
                let imagen,
                let destinoPantalla = view.currentDrawable,
                let ordenes = colaComandos?.makeCommandBuffer()
            else { return }

            let tamanoLienzo = view.drawableSize
            guard tamanoLienzo.width > 0, tamanoLienzo.height > 0 else { return }

            // --- Encajar la imagen entera en el lienzo (aspecto intacto) ---
            // Como colocar el fotograma bajo la lupa: se reduce lo justo para
            // que quepa completo, sin deformarlo, y se centra.
            let extension_ = imagen.extent
            let escalaEncaje = min(tamanoLienzo.width / extension_.width,
                                   tamanoLienzo.height / extension_.height)
            var imagenEncajada = imagen
                // Llevar la esquina de la imagen al origen (0,0)...
                .transformed(by: .init(translationX: -extension_.origin.x,
                                       y: -extension_.origin.y))
                // ...reducirla para que quepa...
                .transformed(by: .init(scaleX: escalaEncaje, y: escalaEncaje))
                // ...y centrarla en el lienzo.
                .transformed(by: .init(
                    translationX: (tamanoLienzo.width - extension_.width * escalaEncaje) / 2,
                    y: (tamanoLienzo.height - extension_.height * escalaEncaje) / 2))

            // Zoom del usuario: ampliar alrededor del centro del lienzo y
            // aplicar el desplazamiento (convertido de puntos de pantalla a
            // píxeles del lienzo; el eje Y de pantalla va al revés que el
            // de la imagen).
            if escala > 1 {
                let centroX = tamanoLienzo.width / 2
                let centroY = tamanoLienzo.height / 2
                let factorPantalla = view.bounds.width > 0
                    ? tamanoLienzo.width / view.bounds.width
                    : 1
                imagenEncajada = imagenEncajada
                    .transformed(by: CGAffineTransform(translationX: centroX, y: centroY)
                        .scaledBy(x: escala, y: escala)
                        .translatedBy(x: -centroX, y: -centroY))
                    .transformed(by: .init(
                        translationX: desplazamiento.width * factorPantalla,
                        y: -desplazamiento.height * factorPantalla))
            }

            // --- Render único (§5.4): toda la cadena, una sola pasada ---
            // El destino es directamente la textura de pantalla, en el formato
            // de 16 bits configurado arriba y con salida Display P3 (§5.3).
            let destino = CIRenderDestination(
                width: Int(tamanoLienzo.width),
                height: Int(tamanoLienzo.height),
                pixelFormat: view.colorPixelFormat,
                commandBuffer: ordenes,
                mtlTextureProvider: { destinoPantalla.texture })
            destino.colorSpace = MotorRevelado.compartido.espacioSalidaPantalla

            do {
                try MotorRevelado.compartido.contexto
                    .startTask(toRender: imagenEncajada, to: destino)
            } catch {
                // Si el render falla no hay nada que enseñar; el error real
                // se verá al decodificar, que es donde damos mensajes claros.
                return
            }

            ordenes.present(destinoPantalla)
            ordenes.commit()
        }
    }
}
