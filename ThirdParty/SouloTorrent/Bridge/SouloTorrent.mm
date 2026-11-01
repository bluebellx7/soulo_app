#import "SouloTorrent.h"
#include <libtorrent/session.hpp>
#include <libtorrent/session_params.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/write_resume_data.hpp>
#include <libtorrent/hex.hpp>
#include <libtorrent/alert.hpp>
#include <map>
#include <set>
#include <stdexcept>
namespace lt = libtorrent;
static NSString *str(std::string const& value) { return [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding] ?: @""; }
static void failure(NSError **error, std::exception const& e) {
    if (error) *error = [NSError errorWithDomain:@"SouloTorrent" code:1 userInfo:@{NSLocalizedDescriptionKey:str(e.what())}];
}
static lt::span<char const> bytes(NSData *data) { return {static_cast<char const *>(data.bytes), static_cast<lt::span<char const>::difference_type>(data.length)}; }
static NSDictionary *describe(std::shared_ptr<lt::torrent_info const> const& ti) {
    if (!ti || !ti->is_valid() || ti->num_files() > 5000) throw std::runtime_error("Invalid torrent or too many files");
    auto const& fs = ti->files();
    NSMutableArray *files = [NSMutableArray array];
    for (auto i : fs.file_range()) {
        NSString *path = str(fs.file_path(i));
        bool pad = bool(fs.file_flags(i) & lt::file_storage::flag_pad_file);
        if (bool(fs.file_flags(i) & lt::file_storage::flag_symlink) || fs.file_size(i) < 0
            || path.length == 0 || path.isAbsolutePath || [path.pathComponents containsObject:@".."])
            throw std::runtime_error("Unsafe torrent file path");
        [files addObject:@{@"index":@(static_cast<int>(i)), @"path":path, @"size":@(fs.file_size(i)), @"pad":@(pad)}];
    }
    auto hashes = ti->info_hashes();
    std::string hash = hashes.has_v2() ? lt::aux::to_hex({hashes.v2.data(), hashes.v2.size()}) : lt::aux::to_hex({hashes.v1.data(), hashes.v1.size()});
    return @{@"name":str(ti->name()), @"hash":str(hash), @"files":files};
}
@implementation SLTorrentEngine {
    std::unique_ptr<lt::session> _session;
    bool _discoveryEnabled;
    std::map<std::string, lt::torrent_handle> _handles;
    std::set<std::string> _metadataOnly;
    struct PeerRefresh { std::vector<lt::tcp::endpoint> peers; std::vector<lt::download_priority_t> priorities; };
    std::map<std::string, PeerRefresh> _peerRefresh;
}
- (instancetype)initWithCertificateFile:(NSString *)certificateFile discoveryEnabled:(BOOL)discoveryEnabled {
    if ((self = [super init])) {
        _discoveryEnabled = discoveryEnabled;
        if (certificateFile.length) setenv("SSL_CERT_FILE", certificateFile.fileSystemRepresentation, 1);
        lt::settings_pack settings;
        settings.set_str(lt::settings_pack::user_agent, "Soulo libtorrent/2.0.15");
        settings.set_str(lt::settings_pack::listen_interfaces, "0.0.0.0:0,[::]:0");
        settings.set_bool(lt::settings_pack::enable_dht, discoveryEnabled);
        if (discoveryEnabled) {
            // A trackerless magnet must not depend on one bootstrap provider.
            // Keep libtorrent's router and an independent DHT entry point.
            settings.set_str(lt::settings_pack::dht_bootstrap_nodes,
                "dht.libtorrent.org:25401,dht.transmissionbt.com:6881");
        }
        settings.set_bool(lt::settings_pack::enable_lsd, false);
        settings.set_bool(lt::settings_pack::enable_upnp, false);
        settings.set_bool(lt::settings_pack::enable_natpmp, false);
        settings.set_bool(lt::settings_pack::validate_https_trackers, true);
        settings.set_int(lt::settings_pack::connections_limit, 80);
        settings.set_int(lt::settings_pack::active_downloads, 3);
        settings.set_int(lt::settings_pack::active_limit, 3);
        settings.set_int(lt::settings_pack::alert_mask, static_cast<int>(static_cast<std::uint32_t>(lt::alert_category::error)));
        _session = std::make_unique<lt::session>(settings);
    }
    return self;
}
+ (NSDictionary *)inspectData:(NSData *)data error:(NSError **)error {
    try {
        if (data.length == 0 || data.length > 8*1024*1024) throw std::runtime_error("Invalid torrent size");
        lt::error_code ec;
        auto ti = std::make_shared<lt::torrent_info>(bytes(data), ec, lt::from_span);
        if (ec) throw std::runtime_error(ec.message());
        return describe(ti);
    } catch (std::exception const& e) { failure(error,e); return nil; }
}
+ (NSDictionary *)inspectMagnet:(NSString *)magnet error:(NSError **)error {
    try {
        if (magnet.length > 65536) throw std::runtime_error("Magnet link too long");
        auto p = lt::parse_magnet_uri(magnet.UTF8String);
        auto h = p.info_hashes;
        if (!h.has_v1() && !h.has_v2()) throw std::runtime_error("Missing torrent hash");
        return @{@"name":str(p.name), @"hash":str(h.has_v2() ? lt::aux::to_hex({h.v2.data(), h.v2.size()}) : lt::aux::to_hex({h.v1.data(), h.v1.size()}))};
    } catch (std::exception const& e) { failure(error,e); return nil; }
}
- (BOOL)addIdentifier:(NSString *)identifier data:(NSData *)data magnet:(NSString *)magnet directory:(NSString *)directory resumeData:(NSData *)resumeData priorities:(NSArray<NSNumber *> *)priorities metadataOnly:(BOOL)metadataOnly error:(NSError **)error {
    try {
        if (_handles.count(identifier.UTF8String)) return YES;
        lt::add_torrent_params p;
        if (resumeData.length) {
            lt::error_code ec;
            p = lt::read_resume_data(bytes(resumeData), ec);
            if (ec) {
                if (data.length) p.ti = std::make_shared<lt::torrent_info>(bytes(data), lt::from_span);
                else if (magnet.length) p = lt::parse_magnet_uri(magnet.UTF8String);
                else throw std::runtime_error(ec.message());
            }
        } else if (data.length) {
            if (data.length > 8*1024*1024) throw std::runtime_error("Torrent too large");
            p.ti = std::make_shared<lt::torrent_info>(bytes(data), lt::from_span);
        } else if (magnet.length) p = lt::parse_magnet_uri(magnet.UTF8String);
        else throw std::runtime_error("Missing torrent metadata");
        if (p.ti) describe(p.ti);
        if (_discoveryEnabled && magnet.length && p.trackers.empty() && (!p.ti || !p.ti->priv())) {
            // Bare magnets otherwise rely exclusively on DHT. Keep a bounded
            // tracker fallback for networks where DHT cannot find peers. Explicit
            // trackers, private metainfo and local-only sessions are untouched.
            p.trackers = {"http://tracker.opentrackr.org:1337/announce",
                          "udp://tracker.opentrackr.org:1337/announce"};
            p.tracker_tiers = {0, 1};
        }
        p.save_path = directory.fileSystemRepresentation;
        p.flags &= ~(lt::torrent_flags::paused | lt::torrent_flags::auto_managed | lt::torrent_flags::stop_when_ready);
        p.flags |= lt::torrent_flags::default_dont_download;
        if (metadataOnly) p.flags |= lt::torrent_flags::upload_mode;
        else p.flags &= ~(lt::torrent_flags::upload_mode | lt::torrent_flags::stop_when_ready);
        p.file_priorities.clear();
        for (NSNumber *priority in priorities) p.file_priorities.emplace_back(priority.boolValue ? lt::default_priority : lt::dont_download);
        lt::error_code ec;
        auto handle = _session->add_torrent(p, ec);
        if (ec) throw std::runtime_error(ec.message());
        _handles.emplace(identifier.UTF8String,handle);
        if (metadataOnly) _metadataOnly.insert(identifier.UTF8String);
        return YES;
    } catch (std::exception const& e) { failure(error,e); return NO; }
}
- (NSInteger)listeningPort { return _session->listen_port(); }
- (void)connectIdentifier:(NSString *)identifier host:(NSString *)host port:(NSInteger)port {
    auto it=_handles.find(identifier.UTF8String); if (it==_handles.end() || port<=0 || port>65535) return;
    lt::error_code ec; auto address=lt::make_address(host.UTF8String,ec);
    if (!ec) it->second.connect_peer(lt::tcp::endpoint(address, static_cast<unsigned short>(port)));
}
- (NSArray<NSDictionary<NSString *,id> *> *)snapshots {
    NSMutableArray *result = [NSMutableArray array];
    for (auto [identifier, handle] : _handles) {
        try {
            auto s = handle.status();
            auto refresh = _peerRefresh.find(identifier);
            if (refresh != _peerRefresh.end() && handle.get_file_priorities() == refresh->second.priorities) {
                // Metadata-only peers can be cached as upload-only/non-candidates.
                // Rebuild that cache after file priorities commit, preserving known endpoints.
                handle.clear_peers();
                for (auto const& peer : refresh->second.peers) handle.connect_peer(peer);
                handle.force_reannounce();
                handle.force_dht_announce();
                _peerRefresh.erase(refresh);
            }
            NSMutableDictionary *d = [@{@"id":str(identifier), @"done":@(s.total_wanted_done), @"total":@(s.total_wanted),
              @"speed":@(s.download_payload_rate), @"peers":@(s.num_peers), @"finished":@(s.is_finished && s.has_metadata),
              @"checking":@(s.state == lt::torrent_status::checking_files || s.state == lt::torrent_status::checking_resume_data),
              @"error":str(s.errc ? s.errc.message() : "")} mutableCopy];
            if (s.has_metadata) {
                try { d[@"metadata"] = describe(handle.torrent_file()); }
                catch (std::exception const& e) { handle.pause(); d[@"error"] = str(e.what()); }
                std::vector<std::int64_t> progress; handle.file_progress(progress);
                NSMutableArray *values=[NSMutableArray array]; for (auto v:progress) [values addObject:@(v)]; d[@"fileProgress"]=values;
            }
            [result addObject:d];
        } catch (std::exception const& e) {
            [result addObject:@{@"id":str(identifier),@"error":str(e.what())}];
        }
    }
    // Drain alerts, including asynchronous tracker and disk notifications, so the queue stays bounded.
    std::vector<lt::alert*> alerts; _session->pop_alerts(&alerts);
    return result;
}
- (NSData *)save:(NSString *)identifier error:(NSError **)error {
    try {
        auto it=_handles.find(identifier.UTF8String); if (it==_handles.end()) return nil;
        auto p=it->second.get_resume_data(lt::torrent_handle::save_info_dict);
        auto buffer=lt::write_resume_data_buf(p);
        return [NSData dataWithBytes:buffer.data() length:buffer.size()];
    } catch (std::exception const& e) { failure(error,e); return nil; }
}
- (NSData *)pauseAndSave:(NSString *)identifier error:(NSError **)error {
    auto it=_handles.find(identifier.UTF8String); if (it==_handles.end()) return nil;
    it->second.pause();
    return [self save:identifier error:error];
}
- (void)resumeMetadata:(NSString *)identifier {
    auto it=_handles.find(identifier.UTF8String); if (it==_handles.end()) return;
    it->second.clear_error();
    it->second.unset_flags(lt::torrent_flags::stop_when_ready);
    it->second.set_flags(lt::torrent_flags::upload_mode | lt::torrent_flags::default_dont_download);
    it->second.resume();
}
- (void)resume:(NSString *)identifier priorities:(NSArray<NSNumber *> *)priorities {
    auto it=_handles.find(identifier.UTF8String); if (it==_handles.end()) return;
    auto h=it->second; std::vector<lt::download_priority_t> values;
    for (NSNumber *v:priorities) values.emplace_back(v.boolValue ? lt::default_priority : lt::dont_download);
    if (_metadataOnly.erase(identifier.UTF8String)) {
        std::vector<lt::tcp::endpoint> peers;
        try { peers = h.get_resume_data().peers; } catch (std::exception const&) {}
        _peerRefresh[identifier.UTF8String] = {std::move(peers), values};
    }
    h.clear_error();
    h.prioritize_files(values);
    h.unset_flags(lt::torrent_flags::upload_mode | lt::torrent_flags::stop_when_ready);
    h.resume();
}
- (void)setDownloadLimit:(NSInteger)bytesPerSecond identifier:(NSString *)identifier {
    auto it=_handles.find(identifier.UTF8String); if (it==_handles.end()) return;
    it->second.set_download_limit(static_cast<int>(std::max<NSInteger>(0,std::min<NSInteger>(bytesPerSecond, INT_MAX))));
}
- (BOOL)remove:(NSString *)identifier deleteFiles:(BOOL)deleteFiles {
    auto it=_handles.find(identifier.UTF8String); if (it==_handles.end()) return NO;
    _session->remove_torrent(it->second, deleteFiles ? lt::session::delete_files : lt::remove_flags_t{});
    _handles.erase(it);
    _metadataOnly.erase(identifier.UTF8String);
    _peerRefresh.erase(identifier.UTF8String);
    return YES;
}
@end
