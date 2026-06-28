import AWSBedrockRuntime
import AWSSDKIdentity

enum BedrockError: Error {
    case noStream
}

actor BedrockService {
    private var client: BedrockRuntimeClient?
    private var currentRegion: String = ""
    private var currentProfile: String = ""

    var clientObjectId: ObjectIdentifier? { client.map { ObjectIdentifier($0) } }

    func ensureClient(region: String, profile: String) async throws {
        guard region != currentRegion || profile != currentProfile || client == nil else { return }

        let resolver = ProfileAWSCredentialIdentityResolver(
            profileName: profile == "default" ? nil : profile
        )
        let config = try await BedrockRuntimeClient.BedrockRuntimeClientConfig(
            awsCredentialIdentityResolver: resolver,
            region: region
        )
        client = BedrockRuntimeClient(config: config)
        currentRegion = region
        currentProfile = profile
    }

    func stream(input: ConverseStreamInput) async throws -> AsyncThrowingStream<BedrockRuntimeClientTypes.ConverseStreamOutput, Error> {
        guard let client else { throw BedrockError.noStream }
        let output = try await client.converseStream(input: input)
        guard let stream = output.stream else { throw BedrockError.noStream }
        return stream
    }
}
