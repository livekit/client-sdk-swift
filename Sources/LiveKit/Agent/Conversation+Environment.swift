/*
 * Copyright 2025 LiveKit
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

import SwiftUI

extension EnvironmentValues {
    @Entry var agentName: String? = nil
}

@MainActor
@propertyWrapper
struct LKConversation: DynamicProperty {
    @EnvironmentObject private var conversation: Conversation

    var wrappedValue: Conversation {
        conversation
    }
}

@MainActor
@propertyWrapper
struct LKLocalMedia: DynamicProperty {
    @EnvironmentObject private var localMedia: LocalMedia

    var wrappedValue: LocalMedia {
        localMedia
    }
}

@MainActor
@propertyWrapper
struct LKAgent: DynamicProperty {
    @EnvironmentObject private var conversation: Conversation
    @Environment(\.agentName) private var environmentName

    let agentName: String?

    init(named agentName: String? = nil) {
        self.agentName = agentName
    }

    var wrappedValue: Agent? {
        if let agentName {
            return conversation.agent(named: agentName)
        } else if let environmentName {
            return conversation.agent(named: environmentName)
        }
        return conversation.agents.values.first
    }
}
