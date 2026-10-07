import SwiftUI

struct TransparencyGrid: View {

    var square: CGFloat = 5

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {

        let dark = colorScheme == .dark
        Canvas { context, size in
            let columns = Int(ceil(size.width / square))
            let rows = Int(ceil(size.height / square))
            let squareInk = dark ? Color.white.opacity(0.045) : Color.primary.opacity(0.07)
            for row in 0 ..< rows {
                for column in 0 ..< columns where (row + column).isMultiple(of: 2) {
                    context.fill(
                        Path(CGRect(
                            x: CGFloat(column) * square, y: CGFloat(row) * square,
                            width: square, height: square
                        )),
                        with: .color(squareInk)
                    )
                }
            }
        }
        .background(dark ? Color.black.opacity(0.45) : Color.primary.opacity(0.025))
        .allowsHitTesting(false)
    }
}
