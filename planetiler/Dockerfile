# Builds the Protomaps basemap schema with Planetiler, in-house.
#
# Planetiler's own default profile emits the OpenMapTiles schema; the Protomaps
# basemap is a separate Planetiler *profile* living in protomaps/basemaps, which
# publishes no image -- hence this source build. Using it keeps the same schema
# (boundaries, buildings, earth, landcover, landuse, places, pois, roads, water)
# and therefore the same ready-made styles as build.protomaps.com, while the
# tiles are generated from OUR OWN extract with no external dependency.
#
# Pinned to a commit because the repo's git tags do not track the basemap
# version (tags read 2.x; the schema reports 4.15.2).
ARG BASEMAPS_REF=a50c699adc60a45c899971b1e11275e61f13bfbf

FROM maven:3-eclipse-temurin-22-alpine AS build
ARG BASEMAPS_REF
WORKDIR /src
RUN apk add --no-cache git \
 && git clone --filter=blob:none https://github.com/protomaps/basemaps.git . \
 && git checkout ${BASEMAPS_REF}
WORKDIR /src/tiles
RUN mvn -q dependency:go-offline
RUN mvn -q clean package -DskipTests

FROM eclipse-temurin:22-jre-alpine
WORKDIR /tiles
# Glob rather than the upstream's hardcoded '-HEAD-' name, so a pinned checkout
# still resolves whatever version string Maven stamps on the jar.
COPY --from=build /src/tiles/target/*-with-deps.jar /tiles/protomaps-basemap.jar
COPY build.sh /usr/local/bin/build.sh
RUN chmod +x /usr/local/bin/build.sh
ENTRYPOINT ["/usr/local/bin/build.sh"]
