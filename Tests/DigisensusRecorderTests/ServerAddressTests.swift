import Foundation
import Testing
@testable import DigisensusRecorder

struct ServerAddressTests {
    @Test func versionInTheServerAddressIsNotRepeated() {
        for server in ["https://api.openai.com/v1", "https://api.openai.com/v1/", " https://api.openai.com/v1\n"] {
            #expect(URL.endpoint("v1/audio/transcriptions", on: server)?.absoluteString
                    == "https://api.openai.com/v1/audio/transcriptions")
            #expect(URL.endpoint("v1/chat/completions", on: server)?.absoluteString
                    == "https://api.openai.com/v1/chat/completions")
        }
    }

    @Test func serverAddressWithoutVersionGetsIt() {
        #expect(URL.endpoint("v1/models", on: "https://api.openai.com")?.absoluteString == "https://api.openai.com/v1/models")
        #expect(URL.endpoint("v1/models", on: "http://localhost:8000/")?.absoluteString == "http://localhost:8000/v1/models")
        #expect(URL.endpoint("health", on: "http://localhost:8000")?.absoluteString == "http://localhost:8000/health")
    }

    @Test func serverAddressWithAPathIsTheAPIRoot() {
        #expect(URL.endpoint("v1/models", on: "https://example.com/openai/v1")?.absoluteString
                == "https://example.com/openai/v1/models")
        #expect(URL.endpoint("v1/chat/completions", on: "https://generativelanguage.googleapis.com/v1beta/openai")?.absoluteString
                == "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
    }

    @Test func savedAddressWithAPathKeepsCallingTheSameEndpoints() {
        #expect(URL.apiRoot(fromLegacyAddress: "https://example.com/speech") == "https://example.com/speech/v1")
        #expect(URL.apiRoot(fromLegacyAddress: "https://example.com/speech/") == "https://example.com/speech/v1")
        #expect(URL.apiRoot(fromLegacyAddress: "http://localhost:8000") == "http://localhost:8000")
        #expect(URL.apiRoot(fromLegacyAddress: "http://localhost:8000/") == "http://localhost:8000/")
        #expect(URL.apiRoot(fromLegacyAddress: "https://api.openai.com/v1") == "https://api.openai.com/v1")
        #expect(URL.endpoint("v1/audio/transcriptions", on: URL.apiRoot(fromLegacyAddress: "https://example.com/speech"))?
            .absoluteString == "https://example.com/speech/v1/audio/transcriptions")
    }

    @Test func healthIsCheckedAtTheServerRootFirst() {
        #expect(URL.healthChecks(on: "http://localhost:8000/v1").map(\.absoluteString)
                == ["http://localhost:8000/health", "http://localhost:8000/v1/health"])
        #expect(URL.healthChecks(on: "http://localhost:8000").map(\.absoluteString) == ["http://localhost:8000/health"])
        #expect(URL.healthChecks(on: "localhost:8000").isEmpty)
    }

    @Test func addressWithoutSchemeIsRejected() {
        #expect(URL.endpoint("v1/models", on: "api.openai.com/v1") == nil)
        #expect(URL.endpoint("v1/models", on: "localhost:8000") == nil)
        #expect(URL.endpoint("v1/models", on: "") == nil)
    }

    @Test func savedServerAddressesFindTheirPreset() {
        #expect(AIPreset.matching(server: "https://api.openai.com", for: .transcription).id == "openai")
        #expect(AIPreset.matching(server: "https://api.openai.com/v1/", for: .summary).id == "openai")
        #expect(AIPreset.matching(server: "http://localhost:8000", for: .transcription) == .local)
        #expect(AIPreset.matching(server: "http://localhost:11434", for: .summary).id == "ollama")
        #expect(AIPreset.matching(server: "http://localhost:11434", for: .transcription) == .local,
                "Ollama has no speech-to-text, so it is never the transcription preset")
        #expect(AIPreset.matching(server: "https://whisper.example.com/v1", for: .transcription) == .other)
    }

    @Test func everyFixedPresetHasAValidAddress() {
        for preset in AIPreset.all {
            if let server = preset.server { #expect(URL.endpoint("v1/models", on: server) != nil, "\(preset.name)") }
        }
        #expect(Set(AIPreset.all.map(\.id)).count == AIPreset.all.count)
    }

    @Test func modelListsKeepWhatFitsThePurpose() {
        let openAI = ["gpt-5-mini", "whisper-1", "gpt-4o-transcribe", "gpt-4o-mini-tts", "text-embedding-3-small",
                      "dall-e-3", "omni-moderation-latest", "gpt-realtime", "gpt-4.1"]
        #expect(ModelList.offered(openAI, for: .transcription) == ["whisper-1"])
        #expect(ModelList.offered(openAI, for: .summary) == ["gpt-4.1", "gpt-5-mini"])
        #expect(ModelList.offered(["llama3.2", "qwen3:8b"], for: .transcription) == ["llama3.2", "qwen3:8b"],
                "a server with no recognisable speech model still lists everything")
    }

    @Test func connectionMessageListsAtMostAFewModels() {
        let names = (1...30).map { "model-\($0)" }
        let message = ConnectionCheck.describe(names, model: "qwen", for: .summary)
        #expect(message.hasPrefix("Connected, but it has no model “qwen”. It offers: model-1, model-2,"))
        #expect(message.hasSuffix(", …."))
    }

    @Test func automaticSummaryModelSkipsEmbeddingAndSpeechModels() {
        #expect(ModelList.likelyChatModel(in: ["BAAI/bge-m3", "nomic-embed-text", "whisper-1", "llama3.2"]) == "llama3.2")
        #expect(ModelList.likelyChatModel(in: ["Qwen/Qwen3-8B", "meta-llama/Llama-3.3-70B-Instruct-Turbo"])
                == "meta-llama/Llama-3.3-70B-Instruct-Turbo")
        #expect(ModelList.likelyChatModel(in: ["text-embedding-3-small"]) == nil)
    }

    @Test func connectionWithoutAChosenModelIsNotReportedAsReady() {
        let message = ConnectionCheck.describe(["llama3.2"], model: "", for: .summary)
        #expect(message.hasPrefix("Connected, but no model is chosen."))
    }

    @Test func choosingAServiceFillsItsAddressAndModelAndSharesTheKeyOnlyWithTheSameService() {
        let openAI = AIPreset.named("openai")!
        var summary = SummarySettings()
        summary.use(openAI, for: .summary, keyFrom: TranscriptionSettings())
        summary.apiKey = "sk-openai"
        #expect(summary.server == "https://api.openai.com/v1" && summary.model == "gpt-6-luna")

        var transcription = TranscriptionSettings()
        transcription.apiKey = "local-key"
        transcription.use(openAI, for: .transcription, keyFrom: summary)
        #expect(transcription.apiKey == "sk-openai" && transcription.model == "whisper-1")
        #expect(transcription.sharesService(with: summary))

        transcription.use(AIPreset.named("groq")!, for: .transcription, keyFrom: summary)
        #expect(transcription.apiKey.isEmpty, "a key never travels to another vendor")
        #expect(transcription.server == "https://api.groq.com/openai/v1")

        transcription.use(.local, for: .transcription, keyFrom: summary)
        #expect(transcription.server == TranscriptionSettings.defaultServer && transcription.apiKey.isEmpty)
        summary.use(.other, for: .summary, keyFrom: transcription)
        #expect(summary.server.isEmpty && summary.model.isEmpty)
        #expect(!summary.sharesService(with: transcription))
    }

    @Test func onboardingOffersOnlyServicesThatDoBoth() {
        let both = AIPreset.all.filter { $0.serves(.transcription) && $0.serves(.summary) }.map(\.id)
        #expect(both == ["local", "openai", "mistral", "groq", "together", "other"])
    }
}

