import ResourceStewardCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var apiKeyDraft: String = ""
    @State private var keyStatus: String = JevAPIKey.statusDescription()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("授权级别") {
                    ForEach(AuthorizationLevel.allCases) { level in
                        Button {
                            guard level.isAvailable else { return }
                            coordinator.settings.authorizationLevel = level
                            coordinator.persistSettings()
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: coordinator.settings.authorizationLevel == level
                                      ? "largecircle.fill.circle"
                                      : "circle")
                                    .foregroundStyle(level.isAvailable ? Color.accentColor : Color.secondary)
                                    .padding(.top, 1)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(level.title)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(level.isAvailable ? Color.primary : Color.secondary)
                                    Text(level.footnote)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!level.isAvailable)
                    }
                    sliderRow("采样间隔（秒）", value: intervalBinding, range: 2...10, format: "%.0f")
                }

                section("Jev") {
                    Toggle("启用 Jev 灰区判断", isOn: jevEnabledBinding)
                    HStack(spacing: 8) {
                        Button("TypeSafe") { applyTypeSafePreset() }
                        Button("OpenRouter") { applyOpenRouterPreset() }
                        Spacer()
                    }
                    .controlSize(.small)
                    TextField("Base URL", text: jevBaseURLBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    TextField("模型", text: jevModelBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    SecureField("API Key", text: $apiKeyDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    HStack {
                        Button("保存到钥匙串") {
                            do {
                                try JevKeychain.saveAPIKey(apiKeyDraft)
                                keyStatus = JevAPIKey.statusDescription()
                            } catch {
                                keyStatus = error.localizedDescription
                            }
                        }
                        .controlSize(.small)
                        Button("清除 Key") {
                            _ = JevKeychain.deleteAPIKey()
                            apiKeyDraft = ""
                            keyStatus = JevAPIKey.statusDescription()
                        }
                        .controlSize(.small)
                        Spacer()
                        Text(keyStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                section("数据") {
                    Text(coordinator.store.filePath)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
            .padding(14)
            .onAppear {
                keyStatus = JevAPIKey.statusDescription()
                if apiKeyDraft.isEmpty, JevAPIKey.hasAPIKey {
                    apiKeyDraft = ""
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .modernCard(padding: 10)
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private var intervalBinding: Binding<Double> {
        Binding(
            get: { coordinator.settings.sampleIntervalSeconds },
            set: {
                coordinator.settings.sampleIntervalSeconds = $0
                coordinator.persistSettings()
            }
        )
    }

    private var jevBaseURLBinding: Binding<String> {
        Binding(
            get: { coordinator.settings.jevBaseURL },
            set: {
                coordinator.settings.jevBaseURL = $0
                coordinator.persistSettings()
            }
        )
    }

    private var jevModelBinding: Binding<String> {
        Binding(
            get: { coordinator.settings.jevModel },
            set: {
                coordinator.settings.jevModel = $0
                coordinator.persistSettings()
            }
        )
    }

    private var jevEnabledBinding: Binding<Bool> {
        Binding(
            get: { coordinator.settings.jevReclaimEnabled },
            set: {
                coordinator.settings.jevReclaimEnabled = $0
                coordinator.persistSettings()
            }
        )
    }

    private func applyTypeSafePreset() {
        coordinator.settings.jevBaseURL = JevURLSessionClient.defaultBaseURLString
        coordinator.settings.jevModel = JevQuestions.defaultModel
        coordinator.persistSettings()
    }

    private func applyOpenRouterPreset() {
        coordinator.settings.jevBaseURL = JevURLSessionClient.openRouterBaseURLString
        coordinator.settings.jevModel = JevURLSessionClient.openRouterDefaultModel
        coordinator.persistSettings()
    }
}
