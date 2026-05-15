/*
 * Copyright 2026 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation

/// Configuration for benchmark runs, read from environment variables.
struct BenchmarkConfig {
    let url: String
    let apiKey: String
    let apiSecret: String
    let mode: InfrastructureMode

    enum InfrastructureMode {
        case local
        case cloud(region: String?)
    }

    /// Read benchmark configuration from environment variables.
    ///
    /// Falls back to local defaults (`ws://localhost:7880`, `devkey`/`secret`)
    /// when environment variables are not set or are empty.
    ///
    /// Override with:
    ///   - `LIVEKIT_URL`: WebSocket URL (e.g., `wss://my-project.livekit.cloud`)
    ///   - `LIVEKIT_API_KEY`: API key for token generation
    ///   - `LIVEKIT_API_SECRET`: API secret for token generation
    ///   - `LIVEKIT_BENCHMARK_REGION`: Server region (only used for cloud)
    static func fromEnvironment() -> BenchmarkConfig {
        // GitHub Actions interpolates missing `${{ secrets.X }}` to an empty
        // string, so treat empty values the same as unset to fall back cleanly.
        func env(_ key: String) -> String? {
            guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else { return nil }
            return value
        }

        let url = env("LIVEKIT_URL") ?? "ws://localhost:7880"
        let apiKey = env("LIVEKIT_API_KEY") ?? "devkey"
        let apiSecret = env("LIVEKIT_API_SECRET") ?? "secret"

        // Auto-detect mode from URL
        let mode: InfrastructureMode = if url.hasPrefix("ws://") || url.contains("localhost") {
            .local
        } else {
            .cloud(region: env("LIVEKIT_BENCHMARK_REGION"))
        }

        return BenchmarkConfig(
            url: url,
            apiKey: apiKey,
            apiSecret: apiSecret,
            mode: mode
        )
    }
}

extension BenchmarkConfig.InfrastructureMode: CustomStringConvertible {
    var description: String {
        switch self {
        case .local: "local"
        case let .cloud(region): region.map { "cloud (\($0))" } ?? "cloud"
        }
    }
}
