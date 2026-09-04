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

@testable import LiveKit
import Testing

/// An external log source: one subscription, lowest requested level, console level kept apart.
struct LogSourceTests {
    @Test func lowestRequestedLevelWinsAndConsoleLevelIsItsOwn() {
        let levels = StateSync<[LogLevel]>([])
        let plain = LogSource(begin: { level in levels.mutate { $0 = [level] } },
                              adjust: { level in levels.mutate { $0.append(level) } })
        plain.enable(console: .error)
        #expect(levels.copy() == [.error], "started once, at the console's level")
        plain.enableTelemetry(level: .warning)
        #expect(levels.copy() == [.error, .warning], "lowered for telemetry, not restarted")
        #expect(plain.consoleLevel == .error, "the console still sees only what it asked for")
        plain.enable(console: .error)
        plain.enableTelemetry(level: .warning)
        #expect(levels.copy() == [.error, .warning], "nothing lower asked: no change")
        plain.enable(console: .debug)
        #expect(levels.copy() == [.error, .warning, .debug] && plain.consoleLevel == .debug)
    }
}
