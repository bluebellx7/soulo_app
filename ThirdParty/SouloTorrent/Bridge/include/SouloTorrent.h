#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Call from one serial worker queue. No network or disk work belongs on the UI thread.
@interface SLTorrentEngine : NSObject
- (instancetype)initWithCertificateFile:(NSString *)certificateFile discoveryEnabled:(BOOL)discoveryEnabled;
@property (nonatomic, readonly) NSInteger listeningPort;
- (void)connectIdentifier:(NSString *)identifier host:(NSString *)host port:(NSInteger)port;
+ (nullable NSDictionary<NSString *, id> *)inspectData:(NSData *)data error:(NSError **)error;
+ (nullable NSDictionary<NSString *, id> *)inspectMagnet:(NSString *)magnet error:(NSError **)error;
- (BOOL)addIdentifier:(NSString *)identifier data:(nullable NSData *)data magnet:(nullable NSString *)magnet
           directory:(NSString *)directory resumeData:(nullable NSData *)resumeData
          priorities:(NSArray<NSNumber *> *)priorities metadataOnly:(BOOL)metadataOnly error:(NSError **)error;
- (NSArray<NSDictionary<NSString *, id> *> *)snapshots;
- (nullable NSData *)pauseAndSave:(NSString *)identifier error:(NSError **)error;
- (nullable NSData *)save:(NSString *)identifier error:(NSError **)error;
- (void)resume:(NSString *)identifier priorities:(NSArray<NSNumber *> *)priorities;
- (void)resumeMetadata:(NSString *)identifier;
- (BOOL)remove:(NSString *)identifier deleteFiles:(BOOL)deleteFiles;
- (void)setDownloadLimit:(NSInteger)bytesPerSecond identifier:(NSString *)identifier;
/// Returns only bytes from a hash-verified piece already written to disk.
/// Empty data means the requested piece is still downloading (or the offset is EOF).
/// nil is reserved for NSError so Swift does not import buffering as a thrown error.
- (nullable NSData *)availableDataForIdentifier:(NSString *)identifier fileIndex:(NSInteger)fileIndex
                                       offset:(int64_t)offset maximumLength:(NSInteger)maximumLength
                                        error:(NSError **)error NS_SWIFT_NAME(availableData(id:file:offset:length:));
- (void)endStreaming:(NSString *)identifier NS_SWIFT_NAME(endStreaming(id:));
@end
NS_ASSUME_NONNULL_END
