import SwiftUI
import Charts

// MARK: - Single Metric Area + Line Chart (CPU % or Memory MB)

struct MetricChartCard: View {
    let title: String
    let subtitle: String
    let currentValueText: String
    let secondaryBadgeText: String?
    let icon: String
    let accentColor: Color
    let samples: [MetricSample]
    let valueExtractor: (MetricSample) -> Double
    let maxYHint: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accentColor)
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                }

                Spacer()

                if let secondaryBadgeText {
                    Text(secondaryBadgeText)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }

                Text(currentValueText)
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(accentColor)
            }

            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Chart {
                ForEach(Array(samples.enumerated()), id: \.element.id) { index, sample in
                    let val = valueExtractor(sample)
                    AreaMark(
                        x: .value("Tick", index),
                        y: .value(title, val)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [accentColor.opacity(0.35), accentColor.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value("Tick", index),
                        y: .value(title, val)
                    )
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2.0))
                    .foregroundStyle(accentColor)
                }
            }
            .chartXAxis(.hidden)
            .chartYScale(domain: 0...(max(maxYHint ?? 10.0, (samples.map(valueExtractor).max() ?? 10.0) * 1.18)))
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        .foregroundStyle(Color.secondary.opacity(0.22))
                    AxisValueLabel()
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 125)
            .animation(.easeInOut(duration: 0.25), value: samples.count)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

// MARK: - Dual Series Chart (Network RX/TX or Disk Read/Write)

struct DualMetricChartCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let primaryLabel: String
    let secondaryLabel: String
    let primaryValueText: String
    let secondaryValueText: String
    let primaryColor: Color
    let secondaryColor: Color
    let samples: [MetricSample]
    let primaryExtractor: (MetricSample) -> Double
    let secondaryExtractor: (MetricSample) -> Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(primaryColor)
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                }

                Spacer()

                HStack(spacing: 10) {
                    HStack(spacing: 4) {
                        Circle().fill(primaryColor).frame(width: 6, height: 6)
                        Text("\(primaryLabel): \(primaryValueText)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(primaryColor)
                    }
                    HStack(spacing: 4) {
                        Circle().fill(secondaryColor).frame(width: 6, height: 6)
                        Text("\(secondaryLabel): \(secondaryValueText)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(secondaryColor)
                    }
                }
            }

            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Chart {
                ForEach(Array(samples.enumerated()), id: \.element.id) { index, sample in
                    let pVal = primaryExtractor(sample)
                    let sVal = secondaryExtractor(sample)

                    AreaMark(
                        x: .value("Tick", index),
                        y: .value(primaryLabel, pVal),
                        series: .value("Series", primaryLabel)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [primaryColor.opacity(0.26), primaryColor.opacity(0.01)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value("Tick", index),
                        y: .value(primaryLabel, pVal),
                        series: .value("Series", primaryLabel)
                    )
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 1.8))
                    .foregroundStyle(primaryColor)

                    LineMark(
                        x: .value("Tick", index),
                        y: .value(secondaryLabel, sVal),
                        series: .value("Series", secondaryLabel)
                    )
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 1.8, dash: [4, 2]))
                    .foregroundStyle(secondaryColor)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        .foregroundStyle(Color.secondary.opacity(0.22))
                    AxisValueLabel()
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 125)
            .animation(.easeInOut(duration: 0.25), value: samples.count)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

// MARK: - Compact Sidebar Sparkline

struct MiniSparklineView: View {
    let values: [Double]
    let color: Color

    var body: some View {
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { idx, val in
                AreaMark(
                    x: .value("T", idx),
                    y: .value("V", val)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(
                        colors: [color.opacity(0.32), color.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("T", idx),
                    y: .value("V", val)
                )
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .foregroundStyle(color)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }
}

// MARK: - Per-Container Resource Breakdown Chart

struct ContainerBreakdownBarChart: View {
    let containers: [ContainerItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "chart.bar.xaxis")
                    .foregroundStyle(.cyan)
                Text("Per-Container MicroVM Resource Distribution")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("Live Virtualization.framework Allocations")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Chart(containers) { item in
                BarMark(
                    x: .value("Memory (MB)", item.memoryUsageMBDisplay),
                    y: .value("Container", item.name)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: item.state == .running ? [.cyan, .blue] : [.gray.opacity(0.4), .gray.opacity(0.2)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .cornerRadius(4)
                .annotation(position: .trailing) {
                    Text(String(format: "%.0f MB  •  %.1f%% CPU", item.memoryUsageMBDisplay, item.cpuPercentDisplay))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .chartXAxis {
                AxisMarks(position: .bottom) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    AxisValueLabel()
                        .font(.system(size: 9, design: .monospaced))
                }
            }
            .frame(height: max(130, CGFloat(containers.count) * 32))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

