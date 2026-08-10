load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# The per-chat exceptions screen lives in its own module rather than in SGSettingsUI.
#
# ChatListUI opens it from a chat's long-press menu, but SGSettingsUI pulls in
# PeerNameColorScreen, which reaches ChatMessageItemImpl and from there back to
# ChatListUI — so a ChatListUI -> SGSettingsUI edge closes a dependency cycle and Bazel
# refuses to analyse the build at all. Keeping this screen's deps down to the low-level
# UI modules lets both sides depend on it.
swift_library(
    name = "SGChatExceptionsUI",
    module_name = "SGChatExceptionsUI",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Display:Display",
        "//submodules/Postbox:Postbox",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/ItemListUI:ItemListUI",
        "//submodules/PresentationDataUtils:PresentationDataUtils",
        "//submodules/AccountContext:AccountContext",
        "//Swiftgram/SGSimpleSettings:SGSimpleSettings",
    ],
    visibility = [
        "//visibility:public",
    ],
)
