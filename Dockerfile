# Two stages: one that needs the Swift toolchain, one that does not.
#
# The single-stage image shipped the entire 10.6 GB Swift toolchain, the source tree,
# the tests and the release build cache into production, so every deployed container
# carried a compiler it never used. Compiling and running are separate jobs; only the
# second one has to reach production.

# ---------------------------------------------------------------------------
# Stage 1 — builder. Compiles; nothing from this stage ships except the binary.
# ---------------------------------------------------------------------------
#
# Pinned by immutable digest, not by a moving tag: `swift:latest` let two builds of
# the same commit produce different binaries, because the toolchain could change
# underneath an unchanged repository.
#
# swift:6.3.3 — Swift 6.3.3-RELEASE on Ubuntu 24.04.4 LTS.
# The digest below is the multi-platform image index, so it resolves for both
# linux/amd64 (the platform Railway builds and runs) and linux/arm64.
# The tag is kept alongside it for readability only; the digest is what binds.
FROM swift:6.3.3@sha256:69bf1f0281e13d82c9e49d67c2dd1dcc8c00bad738c860f4323d7078787ec8ea AS builder

WORKDIR /app
COPY . .

RUN swift build -c release

# ---------------------------------------------------------------------------
# Stage 2 — runtime. Carries the Swift runtime libraries and nothing else.
# ---------------------------------------------------------------------------
#
# swift:6.3.3-slim — the runtime-only variant of the exact same 6.3.3 release, on the
# same Ubuntu 24.04.4 base as the builder. Same toolchain version and same base OS on
# both sides is what makes the dynamically linked binary safe to carry across: it is
# linked against these libraries, not merely against something similar.
#
# Pinned the same way and for the same reason, by the multi-platform index digest.
# It carries the 29 Swift runtime shared objects and no compiler.
FROM swift:6.3.3-slim@sha256:39b558fbd38edb169c94b009286e84e9dd08d509f11eff332ca148e5fd453971

WORKDIR /app

# Only the linked release binary crosses the stage boundary. No sources, no tests,
# no .build cache, no toolchain.
#
# The path is kept byte-for-byte: deployment refers to .build/release/AIHOSAssetServer
# and the CMD below is unchanged from the single-stage image, so the container start
# contract Railway relies on does not move.
COPY --from=builder /app/.build/release/AIHOSAssetServer .build/release/AIHOSAssetServer

EXPOSE 8080

CMD [".build/release/AIHOSAssetServer"]
