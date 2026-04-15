@import Foundation;
#import "unarchive.h"
#import "zip.h"

static BOOL createParentDirectoryForPath(NSString *path) {
	NSString *parentPath = [path stringByDeletingLastPathComponent];
	if (parentPath.length == 0) return YES;
	return [[NSFileManager defaultManager] createDirectoryAtPath:parentPath
	                                 withIntermediateDirectories:YES
	                                                  attributes:nil
	                                                       error:nil];
}

int extract(NSString *fileToExtract, NSString *extractionPath) {
	if (fileToExtract.length == 0 || extractionPath.length == 0) {
		return 1;
	}

	int zipError = 0;
	zip_t *archive = zip_open(fileToExtract.fileSystemRepresentation, ZIP_RDONLY, &zipError);
	if (!archive) {
		return 1;
	}

	NSFileManager *fileManager = [NSFileManager defaultManager];
	zip_int64_t entryCount = zip_get_num_entries(archive, 0);
	char buffer[64 * 1024];

	for (zip_uint64_t i = 0; i < (zip_uint64_t)entryCount; i++) {
		const char *entryName = zip_get_name(archive, i, 0);
		if (!entryName) {
			zip_close(archive);
			return 1;
		}

		NSString *relativePath = [NSString stringWithUTF8String:entryName];
		if (relativePath.length == 0) continue;

		NSString *outputPath = [extractionPath stringByAppendingPathComponent:relativePath];
		BOOL isDirectoryEntry = [relativePath hasSuffix:@"/"];
		if (isDirectoryEntry) {
			if (![fileManager createDirectoryAtPath:outputPath
			            withIntermediateDirectories:YES
			                             attributes:nil
			                                  error:nil]) {
				zip_close(archive);
				return 1;
			}
			continue;
		}

		if (!createParentDirectoryForPath(outputPath)) {
			zip_close(archive);
			return 1;
		}

		zip_file_t *zipFile = zip_fopen_index(archive, i, 0);
		if (!zipFile) {
			zip_close(archive);
			return 1;
		}

		FILE *outputFile = fopen(outputPath.fileSystemRepresentation, "wb");
		if (!outputFile) {
			zip_fclose(zipFile);
			zip_close(archive);
			return 1;
		}

		zip_int64_t bytesRead = 0;
		BOOL success = YES;
		while ((bytesRead = zip_fread(zipFile, buffer, sizeof(buffer))) > 0) {
			size_t bytesWritten = fwrite(buffer, 1, (size_t)bytesRead, outputFile);
			if (bytesWritten != (size_t)bytesRead) {
				success = NO;
				break;
			}
		}

		if (bytesRead < 0) {
			success = NO;
		}

		fclose(outputFile);
		zip_fclose(zipFile);

		if (!success) {
			zip_close(archive);
			return 1;
		}
	}

	zip_close(archive);
	return 0;
}
