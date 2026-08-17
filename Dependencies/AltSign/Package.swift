// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "AltSign",
    platforms: [
        .iOS(.v14),
        .macOS(.v11)
    ],

    products: [
        .library(
            name: "AltSign-Static",
            type: .static,
            targets: ["AltSign"]
        ),
        .library(
            name: "AltSign-Dynamic",
            type: .dynamic,
            targets: ["AltSign"]
        ),
        .library(
            name: "OpenSSL",
            targets: ["OpenSSL"]
        )
    ],


    targets: [
        .binaryTarget(
            name: "OpenSSL",
            url: "https://github.com/krzyzanowskim/OpenSSL/releases/download/3.6.2000/OpenSSL.xcframework.zip",
            checksum: "37846a8bd302cb2443eff47f1045ab844d0cd40bf82cc6159cfad9aa5c3eff9e"
        ),

        // ─────────────────────────
        // C / C++ bridge
        // ─────────────────────────
        .target(
            name: "NativeBridge",
            dependencies: [
            ],
            path: ".",
            sources: [
                "NativeBridge/Sources",
                
                "Dependencies/minizip-ng/mz_crypt.c",
                "Dependencies/minizip-ng/mz_crypt_apple.c",
                "Dependencies/minizip-ng/mz_os.c",
                "Dependencies/minizip-ng/mz_os_posix.c",
                "Dependencies/minizip-ng/mz_strm.c",
                "Dependencies/minizip-ng/mz_strm_buf.c",
                "Dependencies/minizip-ng/mz_strm_mem.c",
                "Dependencies/minizip-ng/mz_strm_os_posix.c",
                "Dependencies/minizip-ng/mz_strm_pkcrypt.c",
                "Dependencies/minizip-ng/mz_strm_split.c",
                "Dependencies/minizip-ng/mz_strm_wzaes.c",
                "Dependencies/minizip-ng/mz_strm_zlib.c",
                "Dependencies/minizip-ng/mz_zip.c",
                "Dependencies/minizip-ng/mz_zip_rw.c",

                "Dependencies/ldid/lookup2.c",
                "Dependencies/ldid/libplist/src/base64.c",
                "Dependencies/ldid/libplist/src/bplist.c",
                "Dependencies/ldid/libplist/src/bytearray.c",
                "Dependencies/ldid/libplist/src/common.c",
                "Dependencies/ldid/libplist/src/hashtable.c",
                "Dependencies/ldid/libplist/src/jplist.c",
                "Dependencies/ldid/libplist/src/jsmn.c",
                "Dependencies/ldid/libplist/src/oplist.c",
                "Dependencies/ldid/libplist/src/out-default.c",
                "Dependencies/ldid/libplist/src/out-limd.c",
                "Dependencies/ldid/libplist/src/out-plutil.c",
                "Dependencies/ldid/libplist/src/plist.c",
                "Dependencies/ldid/libplist/src/ptrarray.c",
                "Dependencies/ldid/libplist/src/time64.c",
                "Dependencies/ldid/libplist/src/xplist.c",
                "Dependencies/ldid/libplist/libcnary/node.c",
                "Dependencies/ldid/libplist/libcnary/node_list.c",

                "Dependencies/corecrypto/Sources/ccsrp.m"
            ],

            publicHeadersPath: "NativeBridge/include",

            cSettings: [
                .headerSearchPath("NativeBridge/include"),
                .headerSearchPath("Dependencies/minizip-ng"),

                .headerSearchPath("ldid"),
                .headerSearchPath("Dependencies/ldid"),
                .headerSearchPath("Dependencies/ldid/libplist/include"),
                .headerSearchPath("Dependencies/ldid/libplist/src"),
                .headerSearchPath("Dependencies/ldid/libplist/libcnary/include"),

                .headerSearchPath("Dependencies/corecrypto/include"),
                .headerSearchPath("Dependencies/corecrypto/include/corecrypto"),

                .define("unix", to: "1"),
                .define("HAVE_ZLIB", to: "1"),
                .define("ZLIB_COMPAT", to: "1"),
                .define("HAVE_WZAES", to: "1"),
                .define("HAVE_PKCRYPT", to: "1"),
                .define("CORECRYPTO_DONOT_USE_TRANSPARENT_UNION", to: "1"),
                .define("NOCRYPT"),
                .define("NOUNCRYPT"),

                .unsafeFlags(["-w", "-fvisibility=hidden"])
            ],

            cxxSettings: [
                .headerSearchPath("NativeBridge/include"),
                .headerSearchPath("Dependencies/corecrypto/include"),
                .unsafeFlags(["-w", "-fvisibility=hidden"])
            ],

            linkerSettings: [
                .linkedLibrary("z"),
                .linkedFramework("Security"),
                // .linkedFramework("CommonCrypto"),
                // .linkedFramework("OpenSSL")
            ]
        ),

        // ─────────────────────────
        // Swift-safe bridge
        // ─────────────────────────
        .target(
            name: "SwiftBridge",
            dependencies: ["NativeBridge", "OpenSSL"],
            path: "SwiftBridge",
            sources: [ "." ],
            linkerSettings: [
                .linkedFramework("CryptoKit"),      // AES-GCM, HMAC-SHA256, SHA256
            ]
        ),

       // ─────────────────────────
       // Main Swift target
       // ─────────────────────────
        .target(
            name: "AltSign",
            dependencies: ["SwiftBridge"],
            path: "Sources"
        )
    ],

    cLanguageStandard: .gnu11,
    cxxLanguageStandard: .cxx14
)
