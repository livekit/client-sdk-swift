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
    /// when environment variables are not set.
    ///
    /// Override with:
    ///   - `LIVEKIT_URL`: WebSocket URL (e.g., `wss://my-project.livekit.cloud`)
    ///   - `LIVEKIT_API_KEY`: API key for token generation
    ///   - `LIVEKIT_API_SECRET`: API secret for token generation
    ///   - `LIVEKIT_BENCHMARK_REGION`: Server region (only used for cloud)
    static func fromEnvironment() -> BenchmarkConfig {
        let url = ProcessInfo.processInfo.environment["LIVEKIT_URL"] ?? "ws://localhost:7880"
        let apiKey = ProcessInfo.processInfo.environment["LIVEKIT_API_KEY"] ?? "devkey"
        let apiSecret = ProcessInfo.processInfo.environment["LIVEKIT_API_SECRET"] ?? "secret"

        // Auto-detect mode from URL
        let mode: InfrastructureMode = if url.hasPrefix("ws://") || url.contains("localhost") {
            .local
        } else {
            .cloud(region: ProcessInfo.processInfo.environment["LIVEKIT_BENCHMARK_REGION"])
        }

        return BenchmarkConfig(
            url: url,
            apiKey: apiKey,
            apiSecret: apiSecret,
            mode: mode
        )
    }
}
