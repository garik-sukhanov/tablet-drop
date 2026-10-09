import SwiftUI

struct TransfersBar: View {
    @ObservedObject var session: Session
    @State private var expanded = false

    private var active: [Transfer] { session.transfers.filter { !$0.isFinished } }

    /// Everything added since the queue was last idle.
    private var currentBatch: [Transfer] {
        guard let batch = active.first?.batch else { return [] }
        return session.transfers.filter { $0.batch == batch }
    }

    var body: some View {
        if !session.transfers.isEmpty {
            VStack(spacing: 0) {
                Divider()
                header
                if expanded {
                    Divider()
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(session.transfers.reversed()) { transfer in
                                TransferRow(transfer: transfer,
                                            cancel: { session.cancel(transfer.id) },
                                            retry: { session.retry(transfer.id) })
                                Divider().opacity(0.4)
                            }
                        }
                    }
                    .frame(height: 200)
                }
            }
            .background(.bar)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.up")
                        .font(.caption)
                    Text(summary).font(.callout)
                }
            }
            .buttonStyle(.borderless)

            if !active.isEmpty {
                ProgressView(value: batchFraction)
                    .frame(maxWidth: 220)
                Text(rateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            Spacer()

            if !active.isEmpty {
                Button("Остановить всё") { session.cancelAll() }
                    .buttonStyle(.borderless)
                    .font(.callout)
            } else if session.transfers.contains(where: \.isFinished) {
                Button("Очистить") { session.clearFinished() }
                    .buttonStyle(.borderless)
                    .font(.callout)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var summary: String {
        if active.isEmpty {
            let failed = session.transfers.filter {
                if case .failed = $0.state { return true }
                return false
            }.count
            return failed > 0 ? "Готово · с ошибками: \(failed)" : "Всё скопировано"
        }
        let direction = active.first(where: { $0.state == .active })?.direction ?? active[0].direction
        let title = direction == .toTablet ? "На планшет" : "На Mac"
        return "\(title): осталось \(plural(active.count, "файл", "файла", "файлов"))"
    }

    private var batchFraction: Double {
        let batch = currentBatch.filter { $0.state != .cancelled }
        let total = batch.reduce(Int64(0)) { $0 + max($1.total, 1) }
        let done = batch.reduce(Int64(0)) { sum, t in
            sum + (t.isFinished ? max(t.total, 1) : min(t.bytes, max(t.total, 1)))
        }
        return total > 0 ? Double(done) / Double(total) : 0
    }

    private var rateText: String {
        guard let current = active.first(where: { $0.state == .active }), current.speed > 1 else { return "" }
        let remaining = active.reduce(Int64(0)) { $0 + max($1.total - $1.bytes, 0) }
        let eta = formatETA(Double(remaining) / current.speed)
        return eta.isEmpty ? formatSpeed(current.speed) : "\(formatSpeed(current.speed)) · \(eta)"
    }
}

struct TransferRow: View {
    let transfer: Transfer
    let cancel: () -> Void
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(transfer.name).lineLimit(1)
                switch transfer.state {
                case .active:
                    ProgressView(value: transfer.fraction)
                        .progressViewStyle(.linear)
                    Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
                case .waiting:
                    Text("В очереди · \(formatBytes(transfer.total))").font(.caption).foregroundStyle(.secondary)
                case .cancelled:
                    Text("Отменено").font(.caption).foregroundStyle(.secondary)
                case .done:
                    Text(formatBytes(transfer.total)).font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer()

            if transfer.canRetry {
                Button { retry() } label: { Image(systemName: "arrow.clockwise.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Повторить")
            } else if !transfer.isFinished {
                Button { cancel() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Отменить")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var detail: String {
        let done = formatBytes(transfer.bytes)
        let total = transfer.total > 0 ? formatBytes(transfer.total) : "?"
        let speed = formatSpeed(transfer.speed)
        return speed.isEmpty ? "\(done) из \(total)" : "\(done) из \(total) · \(speed)"
    }

    private var icon: String {
        switch transfer.state {
        case .done:      return "checkmark.circle.fill"
        case .failed:    return "exclamationmark.circle.fill"
        case .cancelled: return "minus.circle.fill"
        default:         return transfer.direction == .toMac ? "arrow.down.circle" : "arrow.up.circle"
        }
    }

    private var tint: Color {
        switch transfer.state {
        case .done:      return .green
        case .failed:    return .red
        case .cancelled: return .secondary
        default:         return .accentColor
        }
    }
}
