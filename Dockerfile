# Pinned by immutable digest, not by a moving tag: `swift:latest` let two builds of
# the same commit produce different binaries, because the toolchain could change
# underneath an unchanged repository.
#
# swift:6.3.3 — Swift 6.3.3-RELEASE on Ubuntu 24.04.4 LTS.
# The digest below is the multi-platform image index, so it resolves for both
# linux/amd64 (the platform Railway builds and runs) and linux/arm64.
# The tag is kept alongside it for readability only; the digest is what binds.
FROM swift:6.3.3@sha256:69bf1f0281e13d82c9e49d67c2dd1dcc8c00bad738c860f4323d7078787ec8ea

WORKDIR /app
COPY . .

RUN swift build -c release

EXPOSE 8080

CMD [".build/release/AIHOSAssetServer"]
