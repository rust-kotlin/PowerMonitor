import SwiftUI

// One compact metric tile inside the menu bar status item.
struct MenuBarBlockView: View {
    let title: String
    let value: String
    // Optional alert color that matches the threshold-based styling used elsewhere in the app.
    var valueColor: Color? = nil
    var width: CGFloat = 32
    
    @State private var isHovering = false
    
    var body: some View {
        VStack(spacing: -1) {
            Text(title)
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(Color.primary.opacity(0.7))
                .padding(.top, 1)
            
            Text(value)
                // Monospaced digits keep the status item from wobbling as numbers refresh.
                .font(.system(size: 12, weight: .bold))
                .monospacedDigit()
                .foregroundColor(valueColor ?? .primary)
                .allowsTightening(true)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: width, height: 24)
        .background(isHovering ? Color.primary.opacity(0.1) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onHover { hover in
            isHovering = hover
        }
    }
}
