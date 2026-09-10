// Generate a MapLibre style for the Planetiler-built basemap.
// Run once; the output is vendored so the map needs no build step at runtime.
const themes = require('protomaps-themes-base');
const fs = require('fs');

// Placeholder only: index.html rewrites every source url and the glyphs url
// to location.origin at load, so this host never reaches the network.
const BASE = process.argv[2] || 'https://map.invalid';

const style = {
  version: 8,
  name: 'Central Ohio OSM',
  // Glyphs come from Martin, generated from the vendored Noto Sans TTFs.
  // Without this, every label silently renders as nothing.
  glyphs: `${BASE}/tiles/font/{fontstack}/{range}`,
  sources: {
    basemap: {
      type: 'vector',
      url: `${BASE}/tiles/basemap`,
      attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> &middot; Natural Earth'
    },
    // Query results are injected here as GeoJSON at runtime. Everything the
    // map draws beyond the basemap comes through this one source, since the
    // Overpass backend returns features rather than tiles.
    results: { type: 'geojson', data: { type: 'FeatureCollection', features: [] } }
  },
  layers: themes.layers('basemap', themes.namedTheme('light'), { lang: 'en' })
};

// Overlay drawn above the whole basemap: polygons, then lines, then points,
// so small features are never buried under large ones.
style.layers.push(
  {
    id: 'results-fill', type: 'fill', source: 'results',
    filter: ['in', ['geometry-type'], ['literal', ['Polygon', 'MultiPolygon']]],
    paint: { 'fill-color': '#e8590c', 'fill-opacity': 0.28 }
  },
  {
    id: 'results-outline', type: 'line', source: 'results',
    filter: ['in', ['geometry-type'], ['literal', ['Polygon', 'MultiPolygon']]],
    paint: { 'line-color': '#e8590c', 'line-width': 1.6 }
  },
  {
    id: 'results-line', type: 'line', source: 'results',
    filter: ['in', ['geometry-type'], ['literal', ['LineString', 'MultiLineString']]],
    paint: { 'line-color': '#e8590c', 'line-width': 3, 'line-opacity': 0.9 }
  },
  {
    id: 'results-point', type: 'circle', source: 'results',
    filter: ['in', ['geometry-type'], ['literal', ['Point', 'MultiPoint']]],
    paint: {
      'circle-radius': ['interpolate', ['linear'], ['zoom'], 8, 3, 14, 6, 18, 10],
      'circle-color': '#e8590c',
      'circle-stroke-color': '#ffffff',
      'circle-stroke-width': 1.5
    }
  },
  {
    id: 'results-label', type: 'symbol', source: 'results',
    minzoom: 13,
    layout: {
      'text-field': ['get', 'name'],
      'text-font': ['Noto Sans Medium'],
      'text-size': 11,
      'text-offset': [0, 1.1],
      'text-anchor': 'top',
      'text-optional': true
    },
    paint: { 'text-color': '#a03800', 'text-halo-color': '#ffffff', 'text-halo-width': 1.5 }
  }
);

fs.writeFileSync('/w/style.json', JSON.stringify(style, null, 1));
console.log('layers:', style.layers.length, '| glyphs:', style.glyphs);
