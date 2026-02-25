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
    let region: String?

    enum InfrastructureMode: String {
        case local
        case cloud
    }

    /// Read benchmark configuration from environment variables.
    ///
    /// Required:
    ///   - `LIVEKIT_URL`: WebSocket URL (e.g., `ws://localhost:7880` or `wss://my-project.livekit.cloud`)
    ///   - `LIVEKIT_API_KEY`: API key for token generation
    ///   - `LIVEKIT_API_SECRET`: API secret for token generation
    ///
    /// Optional:
    ///   - `LIVEKIT_BENCHMARK_MODE`: "local" or "cloud" (auto-detected from URL if not set)
    ///   - `LIVEKIT_BENCHMARK_REGION`: Server region (recorded in environment descriptor)
    static func fromEnvironment() -> BenchmarkConfig {
        guard let url = ProcessInfo.processInfo.environment["LIVEKIT_URL"] else {
            fatalError("LIVEKIT_URL environment variable is required")
        }
        guard let apiKey = ProcessInfo.processInfo.environment["LIVEKIT_API_KEY"] else {
            fatalError("LIVEKIT_API_KEY environment variable is required")
        }
        guard let apiSecret = ProcessInfo.processInfo.environment["LIVEKIT_API_SECRET"] else {
            fatalError("LIVEKIT_API_SECRET environment variable is required")
        }

        let region = ProcessInfo.processInfo.environment["LIVEKIT_BENCHMARK_REGION"]

        let mode: InfrastructureMode = if let modeStr = ProcessInfo.processInfo.environment["LIVEKIT_BENCHMARK_MODE"] {
            InfrastructureMode(rawValue: modeStr) ?? .local
        } else {
            // Auto-detect from URL
            (url.hasPrefix("ws://") || url.contains("localhost")) ? .local : .cloud
        }

        return BenchmarkConfig(
            url: url,
            apiKey: apiKey,
            apiSecret: apiSecret,
            mode: mode,
            region: region
        )
    }
}
