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
#include <fstream>
#include <chrono>
#include <algorithm>
namespace lt = libtorrent;
static constexpr NSUInteger maximumDHTStateBytes = 256 * 1024;
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
    std::vector<std::string> _publicTrackers;
    std::map<std::string, std::set<std::string>> _automaticTrackers;
    std::set<std::string> _metadataTrackerPolicyApplied;
    struct PeerRefresh { std::vector<lt::tcp::endpoint> peers; std::vector<lt::download_priority_t> priorities; };
    std::map<std::string, PeerRefresh> _peerRefresh;
    std::map<std::string, std::map<lt::piece_index_t, std::chrono::steady_clock::time_point>> _streamPieces;
}
- (instancetype)initWithCertificateFile:(NSString *)certificateFile discoveryEnabled:(BOOL)discoveryEnabled {
    return [self initWithCertificateFile:certificateFile discoveryEnabled:discoveryEnabled dhtState:nil];
}
- (instancetype)initWithCertificateFile:(NSString *)certificateFile discoveryEnabled:(BOOL)discoveryEnabled
                               dhtState:(NSData *)dhtState {
    if ((self = [super init])) {
        _discoveryEnabled = discoveryEnabled;
        _publicTrackers = {"udp://tracker.opentrackr.org:1337/announce",
            "http://tracker.opentrackr.org:1337/announce",
            "udp://open.stealth.si:80/announce", "udp://tracker.torrent.eu.org:451/announce",
            "udp://open.demonii.com:1337/announce"};
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
        settings.set_bool(lt::settings_pack::announce_to_all_tiers, true);
        settings.set_int(lt::settings_pack::active_downloads, 3);
        settings.set_int(lt::settings_pack::active_limit, 3);
        settings.set_int(lt::settings_pack::alert_mask, static_cast<int>(static_cast<std::uint32_t>(lt::alert_category::error)));
        lt::session_params params(std::move(settings));
        if (discoveryEnabled && dhtState.length && dhtState.length <= maximumDHTStateBytes) {
            try {
                auto restored = lt::read_session_params(bytes(dhtState), lt::session::save_dht_state);
                params.dht_state = std::move(restored.dht_state);
            } catch (std::exception const&) {
                // A corrupt cache must never prevent tracker or DHT startup.
            }
        }
        _session = std::make_unique<lt::session>(std::move(params));
    }
    return self;
}
- (NSData *)dhtState {
    if (!_discoveryEnabled) return nil;
    try {
        auto params = _session->session_state(lt::session::save_dht_state);
        if (params.dht_state.nodes.empty() && params.dht_state.nodes6.empty()) return nil;
        auto buffer = lt::write_session_params_buf(params, lt::session::save_dht_state);
        if (buffer.empty() || buffer.size() > maximumDHTStateBytes) return nil;
        return [NSData dataWithBytes:buffer.data() length:buffer.size()];
    } catch (std::exception const&) { return nil; }
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
        if (resumeData.length && magnet.length) {
            lt::error_code hintError;
            auto hints = lt::parse_magnet_uri(magnet.UTF8String, hintError);
            auto const hashes = p.ti ? p.ti->info_hashes() : p.info_hashes;
            bool sameTorrent = !hintError && (hints.info_hashes.has_v1() || hints.info_hashes.has_v2())
                && (!hints.info_hashes.has_v1() || hints.info_hashes.v1 == hashes.v1)
                && (!hints.info_hashes.has_v2() || hints.info_hashes.v2 == hashes.v2);
            if (sameTorrent && !hints.trackers.empty()) {
                // A previous build may have saved this task before recognizing
                // HTML-escaped tracker separators. Restore the original hints.
                p.tracker_tiers.resize(p.trackers.size(), 0);
                int tier = p.tracker_tiers.empty() ? 0 : *std::max_element(p.tracker_tiers.begin(), p.tracker_tiers.end()) + 1;
                for (auto const& tracker : hints.trackers) {
                    if (std::find(p.trackers.begin(), p.trackers.end(), tracker) != p.trackers.end()) continue;
                    p.trackers.push_back(tracker);
                    p.tracker_tiers.push_back(std::min(tier++, 255));
                }
            }
        }
        if (p.ti) describe(p.ti);
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
        [self refreshTrackers:identifier.UTF8String handle:handle];
        if (metadataOnly) _metadataOnly.insert(identifier.UTF8String);
        return YES;
    } catch (std::exception const& e) { failure(error,e); return NO; }
}
- (void)refreshTrackers:(std::string const&)identifier handle:(lt::torrent_handle const&)handle {
    if (!_discoveryEnabled) return;
    auto ti = handle.torrent_file();
    bool privateTorrent = ti && ti->priv();
    auto entries = handle.trackers();
    auto &owned = _automaticTrackers[identifier];
    if (ti) {
        for (auto const& tracker : ti->trackers()) owned.erase(tracker.url);
    }
    auto retained = std::remove_if(entries.begin(), entries.end(), [&](auto const& value) {
        if (!owned.count(value.url)) return false;
        if (!privateTorrent && std::find(_publicTrackers.begin(), _publicTrackers.end(), value.url) != _publicTrackers.end()) return false;
        owned.erase(value.url);
        return true;
    });
    bool removed = retained != entries.end();
    entries.erase(retained, entries.end());
    auto existingCount = entries.size();
    if (!privateTorrent) {
        int tier = 0;
        for (auto const& value : entries) tier = std::max(tier, int(value.tier) + 1);
        for (auto const& url : _publicTrackers) {
            if (std::any_of(entries.begin(), entries.end(), [&](auto const& value) { return value.url == url; })) continue;
            lt::announce_entry entry(url); entry.tier = std::min(tier++, 255);
            entries.push_back(entry); owned.insert(url);
        }
    }
    // Do not reset working trackers when metadata arrives or a subscription
    // refresh only adds addresses. Replacement is only needed for removals.
    if (removed) handle.replace_trackers(entries);
    else for (auto i = existingCount; i < entries.size(); ++i) handle.add_tracker(entries[i]);
    if (ti) _metadataTrackerPolicyApplied.insert(identifier);
}
- (void)updatePublicTrackers:(NSArray<NSString *> *)trackers {
    if (!_discoveryEnabled) return;
    std::vector<std::string> values;
    for (NSString *value in trackers) {
        if (values.size() >= 24) break;
        NSURL *url = [NSURL URLWithString:value];
        if (value.length > 512 || !url.host.length || url.user.length || url.password.length
            || ![@[@"udp", @"http", @"https"] containsObject:url.scheme.lowercaseString]) continue;
        std::string text = value.UTF8String;
        if (std::find(values.begin(), values.end(), text) == values.end()) values.push_back(text);
    }
    if (values.empty() || values == _publicTrackers) return;
    _publicTrackers = std::move(values);
    for (auto const& [identifier, handle] : _handles) {
        try { [self refreshTrackers:identifier handle:handle]; } catch (std::exception const&) {}
    }
}
- (NSArray<NSString *> *)trackerURLs:(NSString *)identifier {
    NSMutableArray *urls = [NSMutableArray array];
    auto found = _handles.find(identifier.UTF8String); if (found == _handles.end()) return urls;
    try { for (auto const& entry : found->second.trackers()) [urls addObject:str(entry.url)]; } catch (std::exception const&) {}
    return urls;
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
            if (s.has_metadata && !_metadataTrackerPolicyApplied.count(identifier))
                [self refreshTrackers:identifier handle:handle];
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
              @"speed":@(s.download_payload_rate), @"peers":@(s.num_peers), @"knownPeers":@(s.list_peers),
              @"seeders":@(s.num_seeds), @"finished":@(s.is_finished && s.has_metadata),
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
- (NSData *)availableDataForIdentifier:(NSString *)identifier fileIndex:(NSInteger)fileIndex offset:(int64_t)offset maximumLength:(NSInteger)maximumLength error:(NSError **)error {
    try {
        auto found = _handles.find(identifier.UTF8String);
        if (found == _handles.end()) throw std::runtime_error("Torrent is no longer available");
        auto handle = found->second;
        auto ti = handle.torrent_file();
        if (!ti || fileIndex < 0 || fileIndex >= ti->num_files() || offset < 0 || maximumLength <= 0)
            throw std::runtime_error("Invalid torrent stream range");
        auto const& fs = ti->files();
        lt::file_index_t index{static_cast<int>(fileIndex)};
        if (bool(fs.file_flags(index) & (lt::file_storage::flag_pad_file | lt::file_storage::flag_symlink)))
            throw std::runtime_error("Invalid torrent media file");
        // Priorities commit asynchronously when a paused task resumes.
        if (handle.file_priority(index) == lt::dont_download) return [NSData data];
        if (offset >= fs.file_size(index)) return [NSData data];
        auto absolute = fs.file_offset(index) + offset;
        lt::piece_index_t piece{static_cast<int>(absolute / ti->piece_length())};
        auto last = lt::piece_index_t{static_cast<int>((fs.file_offset(index) + fs.file_size(index) - 1) / ti->piece_length())};
        auto& pending = _streamPieces[identifier.UTF8String];
        auto now = std::chrono::steady_clock::now();
        for (auto it = pending.begin(); it != pending.end();) {
            if (now - it->second > std::chrono::seconds(15) || handle.have_piece(it->first)) {
                handle.reset_piece_deadline(it->first); it = pending.erase(it);
            } else ++it;
        }
        // Bounded prefetch around the requested playback/seek position. File
        // priorities and excluded files retain the user's original selection.
        int ahead = std::max(1, std::min(8, 2 * 1024 * 1024 / ti->piece_length()));
        for (int i = 0; i < ahead && static_cast<int>(piece) + i <= static_cast<int>(last); ++i) {
            lt::piece_index_t next{static_cast<int>(piece) + i};
            if (!handle.have_piece(next) && !pending.count(next)) {
                if (pending.size() >= 64) { handle.reset_piece_deadline(pending.begin()->first); pending.erase(pending.begin()); }
                handle.set_piece_deadline(next, 200 + i * 150); pending.emplace(next, now);
            }
        }
        if (!handle.have_piece(piece)) return [NSData data];
        NSInteger count = static_cast<NSInteger>(std::min<std::int64_t>({maximumLength, 128 * 1024,
            fs.file_size(index) - offset, ti->piece_length() - absolute % ti->piece_length()}));
        NSURL *root = [[NSURL fileURLWithPath:str(handle.status(lt::torrent_handle::query_save_path).save_path) isDirectory:YES] URLByResolvingSymlinksInPath];
        NSURL *file = [[root URLByAppendingPathComponent:str(fs.file_path(index))] URLByResolvingSymlinksInPath];
        if (![file.path hasPrefix:[root.path stringByAppendingString:@"/"]]) throw std::runtime_error("Unsafe torrent stream path");
        std::ifstream input(file.fileSystemRepresentation, std::ios::binary);
        if (!input) throw std::runtime_error("Torrent file is unavailable");
        input.seekg(offset);
        NSMutableData *data = [NSMutableData dataWithLength:count];
        input.read(static_cast<char *>(data.mutableBytes), count);
        if (input.gcount() != count) throw std::runtime_error("Torrent file was truncated");
        return data;
    } catch (std::exception const& e) { failure(error,e); return nil; }
}
- (void)endStreaming:(NSString *)identifier {
    auto found = _handles.find(identifier.UTF8String);
    if (found != _handles.end()) { try { found->second.clear_piece_deadlines(); } catch (...) {} }
    _streamPieces.erase(identifier.UTF8String);
}
- (NSData *)save:(NSString *)identifier error:(NSError **)error {
    try {
        auto it=_handles.find(identifier.UTF8String); if (it==_handles.end()) return nil;
        auto p=it->second.get_resume_data(lt::torrent_handle::save_info_dict);
        // Automatic hints are refreshed separately; never persist them as if
        // the publisher/user had supplied them (especially before private metadata).
        auto owned = _automaticTrackers.find(identifier.UTF8String);
        if (owned != _automaticTrackers.end()) {
            std::vector<std::string> trackers; std::vector<int> tiers;
            for (std::size_t n = 0; n < p.trackers.size(); ++n) if (!owned->second.count(p.trackers[n])) {
                trackers.push_back(p.trackers[n]); tiers.push_back(n < p.tracker_tiers.size() ? p.tracker_tiers[n] : 0);
            }
            p.trackers = std::move(trackers); p.tracker_tiers = std::move(tiers);
        }
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
    _automaticTrackers.erase(identifier.UTF8String);
    _metadataTrackerPolicyApplied.erase(identifier.UTF8String);
    _peerRefresh.erase(identifier.UTF8String);
    _streamPieces.erase(identifier.UTF8String);
    return YES;
}
@end
