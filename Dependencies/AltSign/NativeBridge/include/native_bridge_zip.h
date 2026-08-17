//
//  native_bridge_zip.h
//  AltSign
//
//  Created by Magesh K on 25/02/26.
//


#pragma once
#include "native_bridge_common.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef void* native_bridge_unzFile;
typedef void* native_bridge_zipFile;

/* unzip */

NATIVE_BRIDGE_EXPORT native_bridge_unzFile native_bridge_unzOpen(const char *path);
NATIVE_BRIDGE_EXPORT native_bridge_unzFile native_bridge_unzOpenWithStatus(const char *path, int32_t *status);
NATIVE_BRIDGE_EXPORT int native_bridge_unzClose(native_bridge_unzFile file);

NATIVE_BRIDGE_EXPORT int native_bridge_unzGetGlobalInfo(native_bridge_unzFile file, void *info);
NATIVE_BRIDGE_EXPORT int native_bridge_unzGoToFirstFile(native_bridge_unzFile file);
NATIVE_BRIDGE_EXPORT int native_bridge_unzGoToNextFile(native_bridge_unzFile file);

NATIVE_BRIDGE_EXPORT int native_bridge_unzGetCurrentFileInfo(
    native_bridge_unzFile file,
    void *info,
    char *filename,
    unsigned long filenameBufferSize
);

NATIVE_BRIDGE_EXPORT int native_bridge_unzOpenCurrentFile(native_bridge_unzFile file);
NATIVE_BRIDGE_EXPORT int native_bridge_unzReadCurrentFile(native_bridge_unzFile file, void *buffer, unsigned len);
NATIVE_BRIDGE_EXPORT int native_bridge_unzCloseCurrentFile(native_bridge_unzFile file);
NATIVE_BRIDGE_EXPORT int native_bridge_unzExtractCurrentFileToFile(native_bridge_unzFile file, const char *destination_path);

/* zip */

NATIVE_BRIDGE_EXPORT native_bridge_zipFile native_bridge_zipOpen(const char *path);
NATIVE_BRIDGE_EXPORT native_bridge_zipFile native_bridge_zipOpenWithStatus(const char *path, int32_t *status);
NATIVE_BRIDGE_EXPORT int native_bridge_zipOpenNewFileInZip(native_bridge_zipFile file, const char *filename);
NATIVE_BRIDGE_EXPORT int native_bridge_zipOpenNewFileInZipWithPermissions(native_bridge_zipFile file, const char *filename, uint32_t permissions);
NATIVE_BRIDGE_EXPORT int native_bridge_zipWriteInFileInZip(native_bridge_zipFile file, const void *buffer, unsigned len);
NATIVE_BRIDGE_EXPORT int native_bridge_zipAddFile(native_bridge_zipFile file, const char *source_path, const char *filename_in_zip);
NATIVE_BRIDGE_EXPORT void native_bridge_zipSetCompressLevel(native_bridge_zipFile file, int16_t level);
NATIVE_BRIDGE_EXPORT int native_bridge_zipCloseFileInZip(native_bridge_zipFile file);
NATIVE_BRIDGE_EXPORT int native_bridge_zipClose(native_bridge_zipFile file);

NATIVE_BRIDGE_EXPORT uint32_t native_bridge_unzGetCurrentFileExternalAttributes(native_bridge_unzFile file);

#ifdef __cplusplus
}
#endif
