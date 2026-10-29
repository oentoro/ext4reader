// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ext4reader",
    platforms: [.macOS(.v14)],
    products: [.library(name: "Ext4Kit", targets: ["Ext4Kit"])],
    targets: [
        .target(
            name: "CLwext4",
            path: "Sources/CLwext4",
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [
                .define("CONFIG_USE_DEFAULT_CFG", to: "1"),
                .define("CONFIG_DEBUG_PRINTF", to: "0"),
                .define("CONFIG_DEBUG_ASSERT", to: "0"),
                .define("CONFIG_JOURNALING_ENABLE", to: "1"),
                .define("CONFIG_EXT4_MOUNTPOINTS_COUNT", to: "4"),
                .define("CONFIG_EXT4_BLOCKDEVS_COUNT", to: "4"),
            ]
        ),
        .target(name: "Ext4Kit", dependencies: ["CLwext4"], path: "Sources/Ext4Kit"),
        .testTarget(name: "Ext4KitTests", dependencies: ["Ext4Kit"], path: "Tests/Ext4KitTests"),
    ]
)
