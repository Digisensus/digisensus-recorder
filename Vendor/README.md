# Bundled codecs

`lib/libopus.a` and `lib/libogg.a` are static, universal (arm64 + x86_64) builds of
libopus 1.6.1 and libogg 1.3.6, both under the BSD 3-clause license. The license texts live
in `Resources/Licenses` and ship inside the app bundle. Their headers are the public headers
of the `COpusShim` target, which also wraps the variadic `opus_*_ctl` calls for Swift.

Built from the upstream release tarballs with CMake, `-O3`, deployment target macOS 15,
one build per architecture, merged with `lipo -create`:

    cmake -S opus-1.6.1 -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=<arch> \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DOPUS_BUILD_SHARED_LIBRARY=OFF \
      -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF
    cmake -S libogg-1.3.6 -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=<arch> \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DBUILD_SHARED_LIBS=OFF -DINSTALL_DOCS=OFF
