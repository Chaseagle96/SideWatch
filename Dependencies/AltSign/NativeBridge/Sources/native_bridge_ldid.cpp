//
//  native_bridge_ldid.cpp
//  AltSign
//
//  Created by Magesh K on 07/07/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

#include "native_bridge_ldid.h"
#define main ldid_main
#include "../../Dependencies/ldid/ldid.cpp"
#undef main

#include <cstring>
#include <cstdlib>

struct ProgressAdapter : ldid::Progress {
    void (*callback_)(void *);
    void *context_;

    ProgressAdapter(void (*callback)(void *), void *context) : callback_(callback), context_(context) {}

    void operator()(const std::string &) const override {
        if (callback_) callback_(context_);
    }

    void operator()(double) const override {
        if (callback_) callback_(context_);
    }
};

/* --------------------------------------------------------- */
/* C ABI                                                     */
/* --------------------------------------------------------- */

extern "C" {

int native_bridge_ldid_sign(
    const char *appPath,
    const uint8_t *keyData,
    int32_t keyLen,
    const char *(*entitlement_callback)(const char *relativePath, void *context),
    void *entitlement_context,
    void (*progress_callback)(void *context),
    void *progress_context,
    char **errorMessage
){
    try {
        if (!appPath) {
            if (errorMessage) {
                *errorMessage = strdup("Invalid arguments: appPath is null");
            }
            return 1;
        }
        if (!keyData || keyLen <= 0) {
            if (errorMessage) {
                *errorMessage = strdup("Invalid arguments: keyData is null or empty");
            }
            return 2;
        }

        std::string keyBytes(reinterpret_cast<const char *>(keyData), keyLen);
        ldid::DiskFolder appBundle(appPath);
        ProgressAdapter progress(progress_callback, progress_context);

        ldid::Sign("", appBundle, keyBytes, "",
            ldid::fun([&](const std::string &path, const std::string &) -> std::string {
                if (!entitlement_callback) return "";
                const char *res = entitlement_callback(path.c_str(), entitlement_context);
                return res ? std::string(res) : "";
            }),
            progress
        );

        return 0;
    }
    catch (const std::exception &e) {
        if (errorMessage) {
            *errorMessage = strdup(e.what());
        }
        return 3;
    }
}

} // extern "C"
