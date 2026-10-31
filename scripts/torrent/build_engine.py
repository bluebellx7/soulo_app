#!/usr/bin/env python3
"""Build the pinned native BT engine; requires Xcode, CMake and standard macOS build tools.
Source archives are verified before extraction. No Homebrew binary is linked into iOS.
"""
import argparse, hashlib, json, os, pathlib, shutil, subprocess, tarfile, urllib.request
ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCES = {
 'libtorrent': ('https://codeload.github.com/arvidn/libtorrent/tar.gz/1eb18faeae156d8dbbab42935c082f8b81f50989', '192fedf8a8d8bf88d097a7956612d0890e2f01a622ca3a00918ef0835c67a257'),
 'boost': ('https://archives.boost.io/release/1.88.0/source/boost_1_88_0.tar.bz2', '46d9d2c06637b219270877c9e16155cbd015b6dc84349af064c088e9b5b12f7b'),
 'openssl': ('https://codeload.github.com/openssl/openssl/tar.gz/refs/tags/openssl-3.6.5', 'f3091b7ccb41a11d877b7406b7afc9dd9c5003d299c6bb33cff882127bc06c91'),
 'try_signal': ('https://codeload.github.com/arvidn/try_signal/tar.gz/105cce59972f925a33aa6b1c3109e4cd3caf583d', '6f111b0d77429a8051be4faed06cf23fb03cf6ee233967c84fdd9d8d3b42ba8e'),
}
def run(args, **kwargs):
 print('+', ' '.join(map(str,args)), flush=True)
 subprocess.run(list(map(str,args)),check=True,**kwargs)
def source(cache, name):
 url,digest=SOURCES[name]; suffix='.tar.bz2' if name=='boost' else '.tar.gz'
 archive=cache/(name+suffix); destination=cache/name
 if not archive.exists():
  temp=archive.with_suffix('.download')
  run(['curl','--fail','--location','--connect-timeout','20','--max-time','600','--retry','3','-o',temp,url]);temp.rename(archive)
 with archive.open('rb') as f: actual=hashlib.file_digest(f,'sha256').hexdigest() if hasattr(hashlib,'file_digest') else hashlib.sha256(f.read()).hexdigest()
 if actual!=digest: raise RuntimeError('Checksum mismatch: '+name+' '+actual)
 if not destination.exists():
  with tarfile.open(archive) as f:
   prefix=f.getmembers()[0].name.split('/')[0]
   for member in f:
    if member.name.startswith('/') or '..' in pathlib.PurePosixPath(member.name).parts: raise RuntimeError('Unsafe archive path')
  run(['tar','-xf',archive,'-C',cache]);(cache/prefix).rename(destination)
 return destination

def main():
 parser=argparse.ArgumentParser();parser.add_argument('--cache',type=pathlib.Path,default=pathlib.Path.home()/'Library/Caches/SouloTorrentBuild')
 parser.add_argument('--slices',nargs='+',default=['device-arm64','sim-arm64','sim-x86_64']);parser.add_argument('--jobs',default='8');parser.add_argument('--package',action='store_true')
 args=parser.parse_args();cache=args.cache.resolve();cache.mkdir(parents=True,exist_ok=True)
 deps={k:source(cache,k) for k in SOURCES}
 signal=deps['libtorrent']/'deps/try_signal'
 if not (signal/'try_signal.cpp').exists(): shutil.copytree(deps['try_signal'],signal,dirs_exist_ok=True)
 for slice in args.slices:
  sim=slice.startswith('sim');arch=slice.split('-')[-1];sdk='iphonesimulator' if sim else 'iphoneos'
  sdkpath=subprocess.check_output(['xcrun','--sdk',sdk,'--show-sdk-path'],text=True).strip()
  work=cache/('build-'+slice);work.mkdir(exist_ok=True);ssl=work/'ssl-install';ssl.mkdir(exist_ok=True);sslbuild=work/'ssl';sslbuild.mkdir(exist_ok=True)
  env=dict(os.environ,SDKROOT=sdkpath,CROSS_TOP=str(pathlib.Path(sdkpath).parents[1]),CROSS_SDK=pathlib.Path(sdkpath).name)
  if not (ssl/'lib/libssl.a').exists():
   cfg=['perl',deps['openssl']/'Configure',('iossimulator-'+arch+'-xcrun') if sim else 'ios64-xcrun','no-shared','no-tests','no-module','no-dso','no-asm','--prefix='+str(ssl),('-mios-simulator-version-min=17.0' if sim else '-miphoneos-version-min=17.0')]
   run(cfg,cwd=sslbuild,env=env);run(['make','-j'+args.jobs,'build_libs'],cwd=sslbuild,env=env);run(['make','install_dev'],cwd=sslbuild,env=env)
  build=work/'engine'
  run(['cmake','-S',ROOT/'scripts/torrent','-B',build,'-DCMAKE_BUILD_TYPE=MinSizeRel','-DCMAKE_SYSTEM_NAME=iOS','-DCMAKE_OSX_SYSROOT='+sdkpath,'-DCMAKE_OSX_ARCHITECTURES='+arch,'-DCMAKE_OSX_DEPLOYMENT_TARGET=17.0','-DCMAKE_CXX_FLAGS=-DTORRENT_HAVE_MMAP=0','-DCMAKE_POLICY_VERSION_MINIMUM=3.5','-DLIBTORRENT_SOURCE='+str(deps['libtorrent']),'-DBRIDGE_SOURCE='+str(ROOT/'ThirdParty/SouloTorrent/Bridge'),'-DBoost_INCLUDE_DIR='+str(deps['boost']),'-DBoost_NO_BOOST_CMAKE=ON','-DOPENSSL_ROOT_DIR='+str(ssl),'-DOPENSSL_INCLUDE_DIR='+str(ssl/'include'),'-DOPENSSL_SSL_LIBRARY='+str(ssl/'lib/libssl.a'),'-DOPENSSL_CRYPTO_LIBRARY='+str(ssl/'lib/libcrypto.a'),'-DBUILD_SHARED_LIBS=OFF','-Ddeprecated-functions=OFF','-Dlogging=OFF','-Di2p=OFF'])
  run(['cmake','--build',build,'-j',args.jobs])
  run(['xcrun','libtool','-static','-o',work/'libSouloTorrent.a',build/'libSouloTorrentBridge.a',build/'libtorrent/libtorrent-rasterbar.a',ssl/'lib/libssl.a',ssl/'lib/libcrypto.a'])
 if args.package:
  sim=cache/'sim';sim.mkdir(exist_ok=True)
  run(['xcrun','lipo','-create',cache/'build-sim-arm64/libSouloTorrent.a',cache/'build-sim-x86_64/libSouloTorrent.a','-output',sim/'libSouloTorrent.a'])
  output=ROOT/'ThirdParty/SouloTorrent/Artifacts/SouloTorrent.xcframework'
  if output.exists():shutil.rmtree(output)
  run(['xcodebuild','-create-xcframework','-library',cache/'build-device-arm64/libSouloTorrent.a','-headers',ROOT/'ThirdParty/SouloTorrent/Bridge/include','-library',sim/'libSouloTorrent.a','-headers',ROOT/'ThirdParty/SouloTorrent/Bridge/include','-output',output])
if __name__=='__main__': main()
