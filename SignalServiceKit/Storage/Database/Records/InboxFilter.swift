//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

/// An enumeration describing ways that the inbox (i.e., the main chat list)
/// can be filtered.
public enum InboxFilter: Hashable, Sendable {
    /// Include only chats that have unread messages, or are explicitly marked unread.
    case unread
}
