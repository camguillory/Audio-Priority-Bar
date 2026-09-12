import AudioPriorityCore

@MainActor
final class AppRuntime {
    let model: AppModel
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
                isUsable: { $0.isConnected && jabra.isUsable($0.name) },
                state: { jabra.monitoredState(for: $0.name) }
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
            model?.handleDevicesChanged()
        }
    }

    @discardableResult
    func start() -> Bool {
        jabra.start()
        let isListening = audioObserver.startListening()
        model.start()
        return isListening
    }

    func stop() {
        model.stop()
        audioObserver.stopListening()
        jabra.stop()
    }
}
