import AudioPriorityCore

@MainActor
final class AppRuntime {
    let model: AppModel
    let updates = UpdateChecker()
    private let audioObserver: CoreAudioObserver
    private let jabra: JabraHIDMonitor

    init() {
        let audioObserver = CoreAudioObserver()
        let jabra = JabraHIDMonitor()
        self.audioObserver = audioObserver
        self.jabra = jabra
        model = AppModel(
            store: PriorityStore(),
            audio: AudioOperations(
                devices: CoreAudioProperties.devices,
                defaultDevice: CoreAudioProperties.defaultDevice,
                setDefault: { CoreAudioProperties.setDefault($1, role: $0) },
                outputVolume: CoreAudioProperties.outputVolume,
                setOutputVolume: CoreAudioProperties.setOutputVolume,
                isMuted: { CoreAudioProperties.isMuted($1, role: $0) }
            ),
            link: LinkOperations(
                isUsable: { $0.isConnected && jabra.isUsable($0) },
                state: { jabra.monitoredState(for: $0) }
            )
        )

        audioObserver.onDevicesChanged = { [weak model] in
            model?.handleDevicesChanged()
        }
        audioObserver.onDefaultChanged = { [weak model] role in
            model?.handleDefaultChanged(role)
        }
        audioObserver.onMuteOrVolumeChanged = { [weak model] in
            model?.handleMuteOrVolumeChanged()
        }
        jabra.onLinkChange = { [weak model] in
            model?.handleLinkChanged()
        }
    }

    @discardableResult
    func start() -> Bool {
        jabra.start()
        let isListening = audioObserver.startListening()
        model.start()
        updates.start()
        return isListening
    }

    func stop() {
        // Producers first: once they are down, no callback, timeout or debounce
        // can reach the model and restart work it just tore down.
        jabra.stop()
        audioObserver.stopListening()
        model.stop()
        updates.stop()
    }
}
